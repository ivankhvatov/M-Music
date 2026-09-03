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

    init(session: URLSession = .shared) {
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
            AlbumDetailsCache.shared.invalidateAll()
            return license
        } catch {
            credentials = previous
            throw error
        }
    }

    /// Clears in-memory and persisted credentials.
    func disconnect() {
        credentials = nil
        SubsonicCredentialsStore.clear()
        AlbumDetailsCache.shared.invalidateAll()
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

    private func fetch(_ url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubsonicError.decoding(error.localizedDescription)
        }
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
        let raw = try await fetch(requestURL, method: method)
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
