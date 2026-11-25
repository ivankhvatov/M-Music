import Foundation

/// The parts of Navidrome's own REST API (`/api/...`, the one its web UI uses) that the Subsonic
/// API has no equivalent of — a playlist's uploaded artwork.
///
/// It signs in with the same username and password as `SubsonicClient` (`POST /auth/login`), and
/// sends the token it gets back in `X-ND-Authorization`. The token is kept for as long as the
/// credentials stay the same, and fetched again when the server stops accepting it.
actor NavidromeNativeAPI {
    static let shared = NavidromeNativeAPI()

    enum APIError: LocalizedError {
        /// Uploads are turned off on the server (`EnableArtworkUpload`) and the user isn't an admin.
        case uploadDisabled
        /// The server has no such route: a Navidrome from before playlist artwork uploads.
        case unsupported
        case rejected(status: Int)

        var errorDescription: String? {
            switch self {
            case .uploadDisabled:
                String(localized: "Artwork uploads are turned off on your server.")
            case .unsupported:
                String(localized: "Your server's Navidrome is too old to change a playlist's artwork.")
            case .rejected(let status):
                String(localized: "The server refused the artwork (HTTP status \(status)).")
            }
        }
    }

    private let session: URLSession
    private var token: String?
    /// Whose token `token` is — server and user — so switching either never reuses it.
    private var tokenOwner: String?

    init(session: URLSession = SubsonicClient.makeAPISession()) {
        self.session = session
    }

    // MARK: - Playlist artwork

    /// Whether the user has uploaded artwork for the playlist (as opposed to the one Navidrome
    /// makes from its songs).
    func hasUploadedArtwork(playlistId: String) async throws -> Bool {
        struct Playlist: Decodable { let uploadedImage: String? }
        let data = try await send(path: "api/playlist/\(playlistId)", method: "GET")
        let playlist = try JSONDecoder().decode(Playlist.self, from: data)
        return !(playlist.uploadedImage ?? "").isEmpty
    }

    /// Uploads `imageData` (JPEG or PNG) as the playlist's artwork, replacing any earlier upload.
    func uploadArtwork(playlistId: String, imageData: Data, mimeType: String = "image/jpeg") async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await send(
            path: "api/playlist/\(playlistId)/image", method: "POST",
            body: body, contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    /// Removes the uploaded artwork, so the playlist goes back to Navidrome's own.
    func removeArtwork(playlistId: String) async throws {
        _ = try await send(path: "api/playlist/\(playlistId)/image", method: "DELETE")
    }

    // MARK: - Requests

    private func send(
        path: String, method: String, body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        // A token the server has stopped accepting (expired, or the user's password changed) is
        // replaced once; a second refusal is real.
        do {
            return try await perform(path: path, method: method, body: body, contentType: contentType)
        } catch let error as APIError {
            guard case .rejected(401) = error else { throw error }
            token = nil
            return try await perform(path: path, method: method, body: body, contentType: contentType)
        }
    }

    private func perform(path: String, method: String, body: Data?, contentType: String?) async throws -> Data {
        guard let credentials = SubsonicClient.shared.credentials else { throw SubsonicError.notConfigured }
        guard let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL else {
            throw SubsonicError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await validToken(for: credentials))", forHTTPHeaderField: "X-ND-Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        // Uploading is a bigger request than the API calls the session's timeout is set for.
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 403: throw APIError.uploadDisabled
        case 404 where path.hasSuffix("/image"): throw APIError.unsupported
        default: throw APIError.rejected(status: http.statusCode)
        }
    }

    private func validToken(for credentials: SubsonicCredentials) async throws -> String {
        let owner = "\(credentials.baseURL.absoluteString)|\(credentials.username)"
        if let token, tokenOwner == owner { return token }

        guard let loginURL = URL(string: "auth/login", relativeTo: credentials.baseURL)?.absoluteURL else {
            throw SubsonicError.invalidBaseURL
        }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": credentials.username, "password": credentials.password])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw http.statusCode == 401 ? SubsonicError.server(code: 40, message: "") : SubsonicError.http(status: http.statusCode)
        }
        struct Login: Decodable { let token: String }
        let login: Login
        do {
            login = try JSONDecoder().decode(Login.self, from: data)
        } catch {
            throw SubsonicError.decoding(error.localizedDescription)
        }
        token = login.token
        tokenOwner = owner
        return login.token
    }
}
