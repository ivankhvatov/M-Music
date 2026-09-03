import Foundation

/// `type` values accepted by `getAlbumList`/`getAlbumList2`.
enum AlbumListType: String {
    case random, newest, frequent, recent, starred
    case alphabeticalByName, alphabeticalByArtist
    case byYear, byGenre
    /// `getAlbumList` (non-ID3) only.
    case highest
}

// https://www.subsonic.org/pages/api.jsp#getAlbumList ... #getStarred2
extension SubsonicClient {

    private func albumListParams(
        type: AlbumListType, size: Int, offset: Int,
        fromYear: Int?, toYear: Int?, genre: String?, musicFolderId: String?
    ) -> [URLQueryItem] {
        var params = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "size", value: String(min(size, 500))),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let fromYear { params.append(URLQueryItem(name: "fromYear", value: String(fromYear))) }
        if let toYear { params.append(URLQueryItem(name: "toYear", value: String(toYear))) }
        if let genre { params.append(URLQueryItem(name: "genre", value: genre)) }
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return params
    }

    func getAlbumList(
        type: AlbumListType, size: Int = 10, offset: Int = 0,
        fromYear: Int? = nil, toYear: Int? = nil, genre: String? = nil, musicFolderId: String? = nil
    ) async throws -> [Child] {
        let params = albumListParams(type: type, size: size, offset: offset, fromYear: fromYear, toYear: toYear, genre: genre, musicFolderId: musicFolderId)
        return try await send("getAlbumList", params, as: AlbumList.self)?.album ?? []
    }

    /// Tag-based ("ID3") album lists — the recommended way to list albums.
    func getAlbumList2(
        type: AlbumListType, size: Int = 10, offset: Int = 0,
        fromYear: Int? = nil, toYear: Int? = nil, genre: String? = nil, musicFolderId: String? = nil
    ) async throws -> [AlbumID3] {
        let params = albumListParams(type: type, size: size, offset: offset, fromYear: fromYear, toYear: toYear, genre: genre, musicFolderId: musicFolderId)
        return try await send("getAlbumList2", params, as: AlbumList2.self)?.album ?? []
    }

    func getRandomSongs(
        size: Int = 10, genre: String? = nil, fromYear: Int? = nil, toYear: Int? = nil, musicFolderId: String? = nil
    ) async throws -> [Child] {
        var params = [URLQueryItem(name: "size", value: String(min(size, 500)))]
        if let genre { params.append(URLQueryItem(name: "genre", value: genre)) }
        if let fromYear { params.append(URLQueryItem(name: "fromYear", value: String(fromYear))) }
        if let toYear { params.append(URLQueryItem(name: "toYear", value: String(toYear))) }
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("getRandomSongs", params, as: RandomSongs.self)?.song ?? []
    }

    func getSongsByGenre(genre: String, count: Int = 10, offset: Int = 0, musicFolderId: String? = nil) async throws -> [Child] {
        var params = [
            URLQueryItem(name: "genre", value: genre),
            URLQueryItem(name: "count", value: String(min(count, 500))),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("getSongsByGenre", params, as: SongsByGenre.self)?.song ?? []
    }

    func getNowPlaying() async throws -> [NowPlayingEntry] {
        try await send("getNowPlaying", as: NowPlaying.self)?.entry ?? []
    }

    func getStarred(musicFolderId: String? = nil) async throws -> Starred {
        var params: [URLQueryItem] = []
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("getStarred", params, as: Starred.self) ?? Starred(artist: nil, album: nil, song: nil)
    }

    /// Tag-based ("ID3") starred items — the recommended way to fetch favorites.
    func getStarred2(musicFolderId: String? = nil) async throws -> Starred2 {
        var params: [URLQueryItem] = []
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("getStarred2", params, as: Starred2.self) ?? Starred2(artist: nil, album: nil, song: nil)
    }
}
