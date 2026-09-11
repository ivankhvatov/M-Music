import Foundation
import GRDB

/// A track downloaded ahead of time by `GaplessCacheService` so the transition into it can be
/// truly gapless — one row per song, overwritten if it's cached again (e.g. after the streaming
/// transcode format changed, or the file aged out and was re-fetched).
struct GaplessCacheRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var songId: String
    /// The transcode codec this file was cached at, or `"raw"` for the original file — compared
    /// against what the track would currently resolve to, so a settings change (or turning
    /// transcoding off/on) invalidates a stale cache hit instead of serving the wrong quality.
    var format: String
    /// `0` for `format == "raw"`.
    var bitrate: Int
    var filePath: String
    var fileExtension: String
    var byteSize: Int64
    var cachedAt: Date
    var lastPlayedAt: Date

    var id: String { songId }
    var fileURL: URL { URL(fileURLWithPath: filePath) }

    static let databaseTableName = "gapless_cache"
}
