import Foundation

// https://www.subsonic.org/pages/api.jsp#search2 / #search3
// Note: Navidrome's search doesn't support Lucene query syntax, just simple auto-complete matching.
extension SubsonicClient {

    func search2(
        query: String,
        artistCount: Int = 20, artistOffset: Int = 0,
        albumCount: Int = 20, albumOffset: Int = 0,
        songCount: Int = 20, songOffset: Int = 0,
        musicFolderId: String? = nil
    ) async throws -> SearchResult2 {
        var params = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(artistCount)),
            URLQueryItem(name: "artistOffset", value: String(artistOffset)),
            URLQueryItem(name: "albumCount", value: String(albumCount)),
            URLQueryItem(name: "albumOffset", value: String(albumOffset)),
            URLQueryItem(name: "songCount", value: String(songCount)),
            URLQueryItem(name: "songOffset", value: String(songOffset)),
        ]
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("search2", params, as: SearchResult2.self) ?? SearchResult2(artist: nil, album: nil, song: nil)
    }

    /// Tag-based ("ID3") search — the recommended way to search.
    func search3(
        query: String,
        artistCount: Int = 20, artistOffset: Int = 0,
        albumCount: Int = 20, albumOffset: Int = 0,
        songCount: Int = 20, songOffset: Int = 0,
        musicFolderId: String? = nil
    ) async throws -> SearchResult3 {
        var params = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(artistCount)),
            URLQueryItem(name: "artistOffset", value: String(artistOffset)),
            URLQueryItem(name: "albumCount", value: String(albumCount)),
            URLQueryItem(name: "albumOffset", value: String(albumOffset)),
            URLQueryItem(name: "songCount", value: String(songCount)),
            URLQueryItem(name: "songOffset", value: String(songOffset)),
        ]
        if let musicFolderId { params.append(URLQueryItem(name: "musicFolderId", value: musicFolderId)) }
        return try await send("search3", params, as: SearchResult3.self) ?? SearchResult3(artist: nil, album: nil, song: nil)
    }

    /// Every song in the library, paged to exhaustion. Shared by `SongsListView` and
    /// `LibrarySyncService` — there's no dedicated "list every song" endpoint, so an empty
    /// `search3` query (matches everything) is the standard way clients browse the full library,
    /// paged 500 at a time until a short page signals the end.
    func allSongs() async throws -> [Child] {
        var result: [Child] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = try await search3(
                query: "", artistCount: 0, albumCount: 0, songCount: pageSize, songOffset: offset
            ).song ?? []
            result.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return result
    }
}
