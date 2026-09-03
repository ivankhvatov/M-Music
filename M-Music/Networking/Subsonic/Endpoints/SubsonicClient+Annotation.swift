import Foundation

// https://www.subsonic.org/pages/api.jsp#star ... #scrobble
extension SubsonicClient {

    /// Favorites one or more songs/albums/artists (by id, folder-style `albumId`, or `artistId`).
    func star(ids: [String] = [], albumIds: [String] = [], artistIds: [String] = []) async throws {
        var params = ids.map { URLQueryItem(name: "id", value: $0) }
        params.append(contentsOf: albumIds.map { URLQueryItem(name: "albumId", value: $0) })
        params.append(contentsOf: artistIds.map { URLQueryItem(name: "artistId", value: $0) })
        try await sendVoid("star", params, method: "POST")
    }

    func unstar(ids: [String] = [], albumIds: [String] = [], artistIds: [String] = []) async throws {
        var params = ids.map { URLQueryItem(name: "id", value: $0) }
        params.append(contentsOf: albumIds.map { URLQueryItem(name: "albumId", value: $0) })
        params.append(contentsOf: artistIds.map { URLQueryItem(name: "artistId", value: $0) })
        try await sendVoid("unstar", params, method: "POST")
    }

    /// `rating` is 1-5, or 0 to remove the rating.
    func setRating(id: String, rating: Int) async throws {
        precondition((0...5).contains(rating), "rating must be between 0 and 5")
        let params = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "rating", value: String(rating))]
        try await sendVoid("setRating", params, method: "POST")
    }

    /// Registers playback with the server. Call with `submission: true` once a song has played
    /// long enough to count (Navidrome only marks a song as "played" via `scrobble`, not `stream`).
    /// Call with `submission: false` when playback starts, to update "now playing" for other clients.
    func scrobble(ids: [String], times: [Date]? = nil, submission: Bool = true) async throws {
        var params = ids.map { URLQueryItem(name: "id", value: $0) }
        if let times {
            params.append(contentsOf: times.map { URLQueryItem(name: "time", value: String(Int64($0.timeIntervalSince1970 * 1000))) })
        }
        params.append(URLQueryItem(name: "submission", value: String(submission)))
        try await sendVoid("scrobble", params, method: "POST")
    }
}
