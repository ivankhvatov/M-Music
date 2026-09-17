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
    /// Display metadata only — purely for `PlaybackSettingsView`'s cached-songs list, never used
    /// to resolve playback (that's always by `songId`).
    var title: String
    var artist: String?
    var album: String?
    var albumId: String?

    var id: String { songId }
    /// Reconstructed from the *current* `GaplessCacheDatabase.rootDirectory()` plus just the
    /// stored path's filename — see `DownloadRecord.fileURL`'s doc comment for why: iOS doesn't
    /// guarantee an app's sandbox container path stays the same across installs, so trusting
    /// `filePath`'s stored directory prefix as-is can point at a container that no longer exists.
    var fileURL: URL {
        GaplessCacheDatabase.rootDirectory().appendingPathComponent(URL(fileURLWithPath: filePath).lastPathComponent)
    }

    static let databaseTableName = "gapless_cache"
}
