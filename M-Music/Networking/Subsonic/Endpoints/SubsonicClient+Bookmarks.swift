import Foundation

// https://www.subsonic.org/pages/api.jsp#getBookmarks ... #savePlayQueue
extension SubsonicClient {

    func getBookmarks() async throws -> [Bookmark] {
        try await send("getBookmarks", as: Bookmarks.self)?.bookmark ?? []
    }

    /// `position` is the playback offset in milliseconds.
    func createBookmark(id: String, position: Int, comment: String? = nil) async throws {
        var params = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "position", value: String(position))]
        if let comment { params.append(URLQueryItem(name: "comment", value: comment)) }
        try await sendVoid("createBookmark", params, method: "POST")
    }

    func deleteBookmark(id: String) async throws {
        try await sendVoid("deleteBookmark", [URLQueryItem(name: "id", value: id)], method: "POST")
    }

    /// The cross-device "resume where I left off" queue (distinct from bookmarks on individual songs).
    func getPlayQueue() async throws -> PlayQueue? {
        try await send("getPlayQueue", as: PlayQueue.self)
    }

    /// `current` is the id of the song currently playing; `position` is its offset in milliseconds.
    func savePlayQueue(songIds: [String], current: String? = nil, position: Int? = nil) async throws {
        var params = songIds.map { URLQueryItem(name: "id", value: $0) }
        if let current { params.append(URLQueryItem(name: "current", value: current)) }
        if let position { params.append(URLQueryItem(name: "position", value: String(position))) }
        try await sendVoid("savePlayQueue", params, method: "POST")
    }
}
