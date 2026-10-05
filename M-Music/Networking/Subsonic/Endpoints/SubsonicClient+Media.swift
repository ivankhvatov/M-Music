import Foundation

// https://www.subsonic.org/pages/api.jsp#stream ... #getAvatar
//
// These endpoints return binary data. Prefer the `...URL` builders below when handing a URL
// to `AVPlayer`/`AsyncImage`/`URLSession.downloadTask` — they're synchronous and authenticate
// the same way as every other call. Use the `async` variants only when you need the bytes
// in memory directly.
extension SubsonicClient {

    /// A playable URL for the given song id, suitable for `AVPlayer` or `AVPlayerItem`.
    /// - Parameters:
    ///   - maxBitRate: kbps cap; the server transcodes if needed. `nil`/`0` streams at source quality.
    ///   - format: target format (e.g. "mp3", "raw" to force no transcoding). `nil` lets the server decide.
    func streamURL(forId id: String, maxBitRate: Int? = nil, format: String? = nil) throws -> URL {
        var params = [URLQueryItem(name: "id", value: id)]
        if let maxBitRate { params.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate))) }
        if let format { params.append(URLQueryItem(name: "format", value: format)) }
        return try url(for: "stream", params)
    }

    /// A URL that returns the original file unmodified (for offline downloads).
    func downloadURL(forId id: String) throws -> URL {
        try url(for: "download", [URLQueryItem(name: "id", value: id)])
    }

    /// A URL for a song/album/artist's cover art. `size` requests a square thumbnail of that
    /// many pixels; omit it for the original image.
    func coverArtURL(forId id: String, size: Int? = nil) throws -> URL {
        var params = [URLQueryItem(name: "id", value: id)]
        if let size { params.append(URLQueryItem(name: "size", value: String(size))) }
        return try url(for: "getCoverArt", params)
    }

    func avatarURL(forUsername username: String) throws -> URL {
        try url(for: "getAvatar", [URLQueryItem(name: "username", value: username)])
    }

    /// Downloads the raw audio bytes for a song. Most playback should use `streamURL` with
    /// `AVPlayer` instead; this is for building an offline-download feature.
    func downloadData(forId id: String) async throws -> Data {
        try await fetchData("download", [URLQueryItem(name: "id", value: id)])
    }

    func coverArtData(forId id: String, size: Int? = nil) async throws -> Data {
        var params = [URLQueryItem(name: "id", value: id)]
        if let size { params.append(URLQueryItem(name: "size", value: String(size))) }
        return try await fetchData("getCoverArt", params)
    }

    /// The song's lyrics by id (OpenSubsonic extension) — possibly several sets, synced and plain.
    /// Servers without the extension answer with an error.
    func getLyricsBySongId(id: String) async throws -> [StructuredLyrics] {
        let list = try await send("getLyricsBySongId", [URLQueryItem(name: "id", value: id)], as: LyricsList.self)
        return list?.structuredLyrics ?? []
    }

    /// Looks up lyrics by artist/title tag match (not by song id). Either parameter may be omitted.
    func getLyrics(artist: String? = nil, title: String? = nil) async throws -> Lyrics {
        var params: [URLQueryItem] = []
        if let artist { params.append(URLQueryItem(name: "artist", value: artist)) }
        if let title { params.append(URLQueryItem(name: "title", value: title)) }
        return try await send("getLyrics", params, as: Lyrics.self) ?? Lyrics(artist: nil, title: nil, value: nil)
    }
}
