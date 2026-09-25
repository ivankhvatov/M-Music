import Foundation
import CryptoKit

/// A client for the Subsonic API (https://www.subsonic.org/pages/api.jsp), targeting the
/// subset implemented by Navidrome (https://www.navidrome.org/docs/developers/subsonic-api/).
///
/// `SubsonicClient` itself only knows how to authenticate, build request URLs, and decode
/// the `{"subsonic-response": {...}}` envelope every endpoint returns. The actual endpoints
/// are implemented as `extension SubsonicClient { ... }` blocks grouped by category under
/// `Networking/Subsonic/Endpoints/`, mirroring the sections of the Subsonic API docs.
///
/// Credential access is synchronous (backed by a lock) so SwiftUI views can build media URLs
/// — e.g. `SubsonicClient.shared.coverArtURL(forId:)` for `AsyncImage` — without `await`.
/// Actual network calls are `async throws`.
final class SubsonicClient: @unchecked Sendable {
    static let shared = SubsonicClient()

    /// Sent as the `c` (client identifier) parameter on every request.
    static let clientName = "M-Music"
    /// Sent as the `v` (protocol version) parameter. Navidrome is compatible with 1.16.1.
    static let apiVersion = "1.16.1"

    private let session: URLSession
    private let lock = NSLock()
    private var _credentials: SubsonicCredentials?

    var credentials: SubsonicCredentials? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _credentials
        }
        set {
            lock.lock()
            _credentials = newValue
            lock.unlock()
        }
    }

    var isConfigured: Bool { credentials != nil }

    /// Coalesces identical concurrent GETs — see `InFlightRequests`.
    private let inFlight = InFlightRequests()

    /// A session just for API calls. Every request URL carries a fresh random salt, so no response
    /// is ever served from — or usefully stored in — the URL cache; the shared session would still
    /// write each (potentially large, e.g. 500-album pages) response to disk for nothing.
    static func makeAPISession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }

    init(session: URLSession = SubsonicClient.makeAPISession()) {
        self.session = session
        self._credentials = SubsonicCredentialsStore.load()
    }

    // MARK: - Configuration

    /// Stores the given credentials and verifies them against the server with `getLicense`.
    /// On failure the previous credentials (if any) are restored and nothing is persisted.
    @discardableResult
    func connect(baseURL: URL, username: String, password: String) async throws -> License {
        let candidate = SubsonicCredentials(baseURL: baseURL, username: username, password: password)
        let previous = credentials
        credentials = candidate
        do {
            let license = try await getLicense()
            try SubsonicCredentialsStore.save(candidate)
            await LibraryCacheDatabase.shared.clearAll()
            ImageCache.shared.invalidateAll()
            await LibrarySyncService.shared.start(client: self)
            return license
        } catch {
            credentials = previous
            throw error
        }
    }

    /// Clears in-memory and persisted credentials. The in-memory credentials are cleared first
    /// thing, before any of the slower work; the Keychain, image-cache directory, and
    /// library-cache work that follows is file I/O, and — being `nonisolated async` — runs off
    /// the calling actor (a view's main actor, in practice) rather than blocking it.
    nonisolated func disconnect() async {
        credentials = nil
        SubsonicCredentialsStore.clear()
        ImageCache.shared.invalidateAll()
        await LibraryCacheDatabase.shared.clearAll()
    }

    // MARK: - URL building

    private func authQueryItems(for credentials: SubsonicCredentials) -> [URLQueryItem] {
        let salt = Self.randomSalt()
        let token = Self.md5Hex(credentials.password + salt)
        return [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    /// Builds a fully authenticated URL for a `/rest/<endpoint>` call. Public so views can
    /// build streaming/cover-art/download URLs directly (see `SubsonicClient+Media.swift`).
    func url(for endpoint: String, _ params: [URLQueryItem] = []) throws -> URL {
        guard let credentials else { throw SubsonicError.notConfigured }
        guard
            let restURL = URL(string: "rest/\(endpoint)", relativeTo: credentials.baseURL),
            var components = URLComponents(url: restURL, resolvingAgainstBaseURL: true)
        else { throw SubsonicError.invalidBaseURL }

        components.queryItems = authQueryItems(for: credentials) + params
        guard let url = components.url else { throw SubsonicError.invalidBaseURL }
        return url
    }

    static func randomSalt(length: Int = 12) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }

    // MARK: - Networking primitives

    // NOTE: `fetch`/`send` (and every endpoint built on them) deliberately stay plain nonisolated
    // `async` functions — that's what keeps the network round trip *and* the JSON decoding off the
    // main thread when a SwiftUI view awaits them. Turning on default MainActor isolation or
    // `NonisolatedNonsendingByDefault` would make them inherit the caller's (main) actor.
    private func fetch(_ url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Transport failures (`URLError`, incl. `.cancelled`) and `CancellationError` propagate
        // untouched: callers tell "offline / retry later" and "the view went away" apart from a
        // real decoding problem by the error's type (see `ScrobbleService.isTransient`).
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SubsonicError.http(status: http.statusCode) }
        return data
    }

    /// Calls an endpoint that returns a JSON envelope and decodes its named payload, if present.
    /// Reads use `method: "GET"`; endpoints that mutate state or take unbounded parameter lists
    /// (star ids, playlist song ids, ...) should pass `method: "POST"`.
    @discardableResult
    func send<Payload: SubsonicPayload>(
        _ endpoint: String,
        _ params: [URLQueryItem] = [],
        method: String = "GET",
        as type: Payload.Type
    ) async throws -> Payload? {
        let requestURL = try url(for: endpoint, params)
        let raw: Data
        if method == "GET" {
            // Identical reads in flight at the same moment (e.g. a screen and
            // `LibrarySyncService` both paging `allAlbums`) share one download.
            raw = try await inFlight.data(forKey: coalescingKey(endpoint, params)) { [self] in
                try await fetch(requestURL, method: method)
            }
        } else {
            raw = try await fetch(requestURL, method: method)
        }
        let envelope: SubsonicResponse<Payload>
        do {
            envelope = try JSONDecoder().decode(SubsonicResponse<Payload>.self, from: raw)
        } catch {
            throw SubsonicError.decoding(error.localizedDescription)
        }
        if let error = envelope.error {
            throw SubsonicError.server(code: error.code, message: error.message ?? "Unknown error")
        }
        return envelope.payload
    }

    /// Server + user + endpoint + parameters, without the per-request auth items — so switching
    /// servers mid-flight can never hand one server's response to a caller of another.
    private func coalescingKey(_ endpoint: String, _ params: [URLQueryItem]) -> String {
        let who = credentials.map { "\($0.baseURL.absoluteString)|\($0.username)" } ?? ""
        let query = params.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(who)|\(endpoint)?\(query)"
    }

    /// Convenience for endpoints whose only interesting outcome is success/failure.
    @discardableResult
    func sendVoid(_ endpoint: String, _ params: [URLQueryItem] = [], method: String = "GET") async throws -> Bool {
        _ = try await send(endpoint, params, method: method, as: EmptyPayload.self)
        return true
    }

    /// Calls an endpoint that returns raw binary data (cover art, audio stream, avatar, ...).
    func fetchData(_ endpoint: String, _ params: [URLQueryItem] = []) async throws -> Data {
        let requestURL = try url(for: endpoint, params)
        return try await fetch(requestURL, method: "GET")
    }
}

/// Single-flight for idempotent GETs: while a request for a given key is running, further callers
/// await that same download instead of starting their own. The download runs in its own task, so
/// one caller being cancelled (a screen popped mid-load) doesn't abort it for the others; its
/// result is simply dropped if nobody is left waiting.
private actor InFlightRequests {
    private var tasks: [String: Task<Data, Error>] = [:]

    func data(forKey key: String, start: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let task: Task<Data, Error>
        if let existing = tasks[key] {
            task = existing
        } else {
            task = Task { try await start() }
            tasks[key] = task
            Task { [weak self] in
                _ = await task.result
                await self?.finish(key: key, task: task)
            }
        }
        // A cancelled caller still waits for the shared download to land (it isn't aborted, see
        // above) but throws instead of using the result.
        let data = try await task.value
        try Task.checkCancellation()
        return data
    }

    private func finish(key: String, task: Task<Data, Error>) {
        if tasks[key] == task { tasks[key] = nil }
    }
}
