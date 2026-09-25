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

/// Everything the UI needs to know about downloaded songs, derived from the full record list in one
/// pass — built on a background task by `load(previous:)`, so that neither the derivation nor the
/// "did anything change?" comparison against the previous snapshot ever runs on the main thread.
/// The derived lookups are what make per-row questions ("does this album/artist have any
/// download?", "is this album fully downloaded?") O(1) instead of a scan of every record for every
/// row of every list on every render.
struct DownloadSnapshot: Sendable, Equatable {
    struct AlbumGroup: Sendable, Equatable {
        let albumId: String?
        let albumTitle: String
        let records: [DownloadRecord]
    }

    /// What changed against the previous snapshot — so the main actor assigns only those pieces.
    struct Changes: Sendable {
        let records: Bool
        let songIds: Bool
        let totalBytes: Bool
    }

    var records: [DownloadRecord] = []
    var totalBytes: Int64 = 0

    // Derived from `records`.
    var songIds: Set<String> = []
    var songCountByAlbumId: [String: Int] = [:]
    var artistNames: Set<String> = []
    var recordsByAlbum: [AlbumGroup] = []

    init() {}

    init(records: [DownloadRecord], totalBytes: Int64) {
        self.records = records
        self.totalBytes = totalBytes
        var ids = Set<String>(minimumCapacity: records.count)
        var perAlbum: [String: Int] = [:]
        var artists = Set<String>()
        var grouped: [String?: [DownloadRecord]] = [:]
        for record in records {
            ids.insert(record.songId)
            if let albumId = record.albumId { perAlbum[albumId, default: 0] += 1 }
            if let artist = record.artist { artists.insert(artist) }
            grouped[record.albumId, default: []].append(record)
        }
        songIds = ids
        songCountByAlbumId = perAlbum
        artistNames = artists
        recordsByAlbum = grouped
            .map { albumId, records in
                AlbumGroup(
                    albumId: albumId,
                    albumTitle: records.first?.album ?? String(localized: "Unknown Album"),
                    records: records.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
                )
            }
            .sorted { $0.albumTitle.sortKey < $1.albumTitle.sortKey }
    }

    /// Only the inputs are compared; everything else is a pure function of them.
    static func == (lhs: DownloadSnapshot, rhs: DownloadSnapshot) -> Bool {
        lhs.totalBytes == rhs.totalBytes && lhs.records == rhs.records
    }

    /// Reads the database, builds the snapshot, mirrors it into the synchronous
    /// `LocalDownloadIndex` (thread-safe, and playback needs it current), and compares against
    /// `previous` — all off the main actor. `nil` means nothing changed.
    static func load(previous: DownloadSnapshot) async -> (snapshot: DownloadSnapshot, changes: Changes)? {
        let records = await DownloadDatabase.shared.allRecords()
        let stats = await DownloadDatabase.shared.storageStats()
        let snapshot = DownloadSnapshot(records: records, totalBytes: stats.totalBytes)

        LocalDownloadIndex.shared.replaceAll(Dictionary(uniqueKeysWithValues: records.map {
            ($0.songId, LocalDownloadIndex.Entry(path: $0.fileURL.path, format: $0.format, bitRate: $0.bitRate))
        }))

        let changes = Changes(
            records: snapshot.records != previous.records,
            songIds: snapshot.songIds != previous.songIds,
            totalBytes: snapshot.totalBytes != previous.totalBytes
        )
        guard changes.records || changes.songIds || changes.totalBytes else { return nil }
        return (snapshot, changes)
    }
}
