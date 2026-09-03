import Foundation

// https://www.subsonic.org/pages/api.jsp#getMusicFolders ... #getTopSongs
extension SubsonicClient {

    func getMusicFolders() async throws -> [MusicFolder] {
        try await send("getMusicFolders", as: MusicFolders.self)?.musicFolder ?? []
    }

    /// Folder-style browsing. Navidrome simulates a directory tree from tags rather than
    /// exposing real folders — prefer `getArtists`/`getArtist`/`getAlbum` (ID3) instead.
    func getIndexes(musicFolderId: String? = nil, ifModifiedSince: Int64? = nil) async throws -> Indexes {
        var params: [URLQueryItem] = []
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        if let ifModifiedSince { params.append(URLQueryItem(name: "ifModifiedSince", value: String(ifModifiedSince))) }
        guard let indexes = try await send("getIndexes", params, as: Indexes.self) else {
            throw SubsonicError.invalidResponse
        }
        return indexes
    }

    func getMusicDirectory(id: String) async throws -> Directory {
        guard let directory = try await send("getMusicDirectory", [URLQueryItem(name: "id", value: id)], as: Directory.self) else {
            throw SubsonicError.invalidResponse
        }
        return directory
    }

    func getGenres() async throws -> [Genre] {
        try await send("getGenres", as: Genres.self)?.genre ?? []
    }

    /// Tag-based ("ID3") artist browsing — the recommended way to list artists.
    func getArtists(musicFolderId: String? = nil) async throws -> ArtistsID3 {
        var params: [URLQueryItem] = []
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        guard let artists = try await send("getArtists", params, as: ArtistsID3.self) else {
            throw SubsonicError.invalidResponse
        }
        return artists
    }

    func getArtist(id: String) async throws -> ArtistWithAlbumsID3 {
        guard let artist = try await send("getArtist", [URLQueryItem(name: "id", value: id)], as: ArtistWithAlbumsID3.self) else {
            throw SubsonicError.invalidResponse
        }
        return artist
    }

    func getAlbum(id: String) async throws -> AlbumWithSongsID3 {
        guard let album = try await send("getAlbum", [URLQueryItem(name: "id", value: id)], as: AlbumWithSongsID3.self) else {
            throw SubsonicError.invalidResponse
        }
        return album
    }

    func getSong(id: String) async throws -> Child {
        guard let song = try await send("getSong", [URLQueryItem(name: "id", value: id)], as: Child.self) else {
            throw SubsonicError.invalidResponse
        }
        return song
    }

    /// `id` may be an artist, album, or song id.
    func getArtistInfo(id: String, count: Int = 20, includeNotPresent: Bool = false) async throws -> ArtistInfo {
        let params = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "includeNotPresent", value: String(includeNotPresent)),
        ]
        guard let info = try await send("getArtistInfo", params, as: ArtistInfo.self) else {
            throw SubsonicError.invalidResponse
        }
        return info
    }

    func getArtistInfo2(id: String, count: Int = 20, includeNotPresent: Bool = false) async throws -> ArtistInfo2 {
        let params = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "includeNotPresent", value: String(includeNotPresent)),
        ]
        guard let info = try await send("getArtistInfo2", params, as: ArtistInfo2.self) else {
            throw SubsonicError.invalidResponse
        }
        return info
    }

    /// `id` may be an album or song id.
    func getAlbumInfo(id: String) async throws -> AlbumInfo {
        guard let info = try await send("getAlbumInfo", [URLQueryItem(name: "id", value: id)], as: AlbumInfo.self) else {
            throw SubsonicError.invalidResponse
        }
        return info
    }

    func getAlbumInfo2(id: String) async throws -> AlbumInfo2 {
        guard let info = try await send("getAlbumInfo2", [URLQueryItem(name: "id", value: id)], as: AlbumInfo2.self) else {
            throw SubsonicError.invalidResponse
        }
        return info
    }

    /// `id` may be an artist, album, or song id. Requires Last.fm integration on the server.
    func getSimilarSongs(id: String, count: Int = 50) async throws -> [Child] {
        let params = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "count", value: String(count))]
        return try await send("getSimilarSongs", params, as: SimilarSongs.self)?.song ?? []
    }

    func getSimilarSongs2(id: String, count: Int = 50) async throws -> [Child] {
        let params = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "count", value: String(count))]
        return try await send("getSimilarSongs2", params, as: SimilarSongs2.self)?.song ?? []
    }

    /// Requires Last.fm integration on the server.
    func getTopSongs(artist: String, count: Int = 50) async throws -> [Child] {
        let params = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "count", value: String(count))]
        return try await send("getTopSongs", params, as: TopSongs.self)?.song ?? []
    }
}
