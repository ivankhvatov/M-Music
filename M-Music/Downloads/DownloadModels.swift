import Foundation
import GRDB

/// Ported from Shelv's `ShelvCore/Models/DownloadModels.swift`.
enum DownloadState: Equatable, Sendable {
    case none
    case queued
    case downloading(progress: Double)
    case completed
    case failed(message: String)

    static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.queued, .queued), (.completed, .completed): return true
        case (.downloading(let a), .downloading(let b)): return abs(a - b) < 0.0001
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// A song downloaded to disk, persisted in `DownloadDatabase`. Unlike Shelv's `DownloadedSong`
/// (which is keyed by `serverId::songId` for its multi-server support) this is keyed by `songId`
/// alone — M-Music only ever talks to one `SubsonicClient.shared` server.
struct DownloadRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    var songId: String
    var title: String
    var artist: String?
    var album: String?
    var albumId: String?
    var coverArt: String?
    var track: Int?
    var discNumber: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var filePath: String
    var fileExtension: String
    var contentType: String?
    var bitRate: Int?
    var byteSize: Int64
    var replayGainTrackGain: Double?
    var replayGainAlbumGain: Double?
    var addedAt: Date
    /// `"raw"` for an untranscoded download, or a `TranscodingFormat.rawValue` (e.g. `"mp3"`) for
    /// one downloaded via `DownloadTranscodingSettings` — lets `PlayerManager` tell whether a
    /// download still matches the current streaming quality when
    /// `DownloadTranscodingSettings.prioritizeDownloads` is off, the same way `GaplessCacheRecord`
    /// tracks it for cache entries. `nil` for a download made before this field existed; treated
    /// as always valid (there's no format on record to second-guess it against).
    var format: String?

    var id: String { songId }
    /// Reconstructed from the *current* `DownloadDatabase.rootDirectory()` plus just the stored
    /// path's filename, rather than trusting `filePath`'s directory prefix as-is — iOS doesn't
    /// guarantee an app's sandbox container path stays the same across installs (even one that
    /// overwrites the previous build in place), so a `filePath` written in an earlier install can
    /// point at a container that no longer exists. Self-heals on every read; no migration needed.
    var fileURL: URL {
        DownloadDatabase.rootDirectory().appendingPathComponent(URL(fileURLWithPath: filePath).lastPathComponent)
    }

    static let databaseTableName = "downloads"

    /// Converts back to the `Child` type the player queue and song rows already work with, so a
    /// downloaded song can be queued/displayed exactly like one fetched live from the server.
    func asChild() -> Child {
        let replayGain: ReplayGain? = (replayGainTrackGain != nil || replayGainAlbumGain != nil)
            ? ReplayGain(
                trackGain: replayGainTrackGain, albumGain: replayGainAlbumGain,
                trackPeak: nil, albumPeak: nil, baseGain: nil, fallbackGain: nil
            )
            : nil
        return Child(
            id: FlexibleID(songId), title: title, album: album, artist: artist, track: track,
            year: year, genre: genre, coverArt: coverArt, size: byteSize, contentType: contentType,
            suffix: fileExtension, duration: duration, bitRate: bitRate, discNumber: discNumber,
            starred: nil, albumId: albumId.map { FlexibleID($0) }, artistId: nil, replayGain: replayGain
        )
    }
}

struct DownloadStorageStats {
    let totalBytes: Int64
    let songCount: Int
    let albumCount: Int
}
