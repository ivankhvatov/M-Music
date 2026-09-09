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
struct DownloadRecord: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
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

    var id: String { songId }
    var fileURL: URL { URL(fileURLWithPath: filePath) }

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
