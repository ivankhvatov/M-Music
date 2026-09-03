import Foundation

// https://www.subsonic.org/pages/api.jsp#getPlaylists ... #deletePlaylist
extension SubsonicClient {

    /// Note: Navidrome ignores the `username` filter and always returns the caller's playlists.
    func getPlaylists() async throws -> [PlaylistSummary] {
        try await send("getPlaylists", as: Playlists.self)?.playlist ?? []
    }

    func getPlaylist(id: String) async throws -> PlaylistWithSongs {
        guard let playlist = try await send("getPlaylist", [URLQueryItem(name: "id", value: id)], as: PlaylistWithSongs.self) else {
            throw SubsonicError.invalidResponse
        }
        return playlist
    }

    /// Creates a new playlist named `name` seeded with `songIds` (may be empty).
    @discardableResult
    func createPlaylist(name: String, songIds: [String] = []) async throws -> PlaylistWithSongs? {
        var params = [URLQueryItem(name: "name", value: name)]
        params.append(contentsOf: songIds.map { URLQueryItem(name: "songId", value: $0) })
        return try await send("createPlaylist", params, method: "POST", as: PlaylistWithSongs.self)
    }

    /// Replaces the contents of an existing playlist by id (Subsonic overloads `createPlaylist`
    /// for this when `playlistId` is supplied instead of `name`).
    @discardableResult
    func replacePlaylist(playlistId: String, songIds: [String]) async throws -> PlaylistWithSongs? {
        var params = [URLQueryItem(name: "playlistId", value: playlistId)]
        params.append(contentsOf: songIds.map { URLQueryItem(name: "songId", value: $0) })
        return try await send("createPlaylist", params, method: "POST", as: PlaylistWithSongs.self)
    }

    /// Renames/re-describes a playlist and/or adds/removes songs.
    /// `songIndexToRemove` is the zero-based position of the song *within the playlist*, not its song id.
    func updatePlaylist(
        playlistId: String,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        var params = [URLQueryItem(name: "playlistId", value: playlistId)]
        if let name { params.append(URLQueryItem(name: "name", value: name)) }
        if let comment { params.append(URLQueryItem(name: "comment", value: comment)) }
        if let isPublic { params.append(URLQueryItem(name: "public", value: String(isPublic))) }
        params.append(contentsOf: songIdsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) })
        params.append(contentsOf: songIndexesToRemove.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) })
        try await sendVoid("updatePlaylist", params, method: "POST")
    }

    func deletePlaylist(id: String) async throws {
        try await sendVoid("deletePlaylist", [URLQueryItem(name: "id", value: id)], method: "POST")
    }
}
