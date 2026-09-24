import Foundation
import SwiftUI

/// UI-facing wrapper around `DownloadService` — mirrors the shape of Shelv's `DownloadStore`
/// (`Shelv/ViewModels/DownloadStore.swift`) minus everything server-scoped, since M-Music only
/// ever talks to one server.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var downloadedSongIds: Set<String> = []
    @Published private(set) var progressBySongId: [String: Double] = [:]
    @Published private(set) var downloadedRecords: [DownloadRecord] = []
    @Published private(set) var totalBytes: Int64 = 0

    private var failedSongIds: Set<String> = []
    private var updateObservationTask: Task<Void, Never>?

    private init() {
        Task { await reload() }
        updateObservationTask = Task { [weak self] in
            guard let self else { return }
            for await update in await DownloadService.shared.updates() {
                await self.apply(update)
            }
        }
    }

    func state(for songId: String) -> DownloadState {
        if downloadedSongIds.contains(songId) { return .completed }
        if let progress = progressBySongId[songId] { return .downloading(progress: progress) }
        if failedSongIds.contains(songId) { return .failed(message: "") }
        return .none
    }

    func isDownloaded(_ songId: String) -> Bool {
        downloadedSongIds.contains(songId)
    }

    /// Whether *any* song from this album is downloaded — used to decide whether an album's own
    /// preview card/row should read as available offline, as opposed to `AlbumView
    /// .isAlbumDownloaded`'s stricter "every song downloaded" (that one drives the toolbar
    /// download button, a different question).
    func hasDownloadedSong(inAlbum albumId: String?) -> Bool {
        guard let albumId else { return false }
        return downloadedRecords.contains { $0.albumId == albumId }
    }

    /// Whether any downloaded song's `artist` field matches `artistName` — the only signal
    /// available for this without a heavier artist-id lookup, since `DownloadRecord` only ever
    /// stores the artist's name (the same string `ArtistID3.name` uses), not an id.
    func hasDownloadedSong(byArtist artistName: String?) -> Bool {
        guard let artistName else { return false }
        return downloadedRecords.contains { $0.artist == artistName }
    }

    func download(_ song: Child) {
        guard !downloadedSongIds.contains(song.id.raw) else { return }
        failedSongIds.remove(song.id.raw)
        progressBySongId[song.id.raw] = 0
        Task { await DownloadService.shared.enqueue(song: song) }
    }

    func downloadAlbum(_ songs: [Child]) {
        let missing = songs.filter { !downloadedSongIds.contains($0.id.raw) }
        guard !missing.isEmpty else { return }
        for song in missing {
            failedSongIds.remove(song.id.raw)
            progressBySongId[song.id.raw] = 0
        }
        Task { await DownloadService.shared.enqueueAlbum(songs: missing) }
    }

    func remove(songId: String) {
        Task {
            await DownloadService.shared.delete(songId: songId)
            await reload()
        }
    }

    func removeAlbum(albumId: String) {
        Task {
            await DownloadService.shared.deleteAlbum(albumId: albumId)
            await reload()
        }
    }

    func removeAll() {
        Task {
            await DownloadService.shared.deleteAll()
            await reload()
        }
    }

    /// Not `private` — `PlayerManager` also awaits this directly (see its `init()`/`resume()`),
    /// since `DownloadStore.shared` is otherwise only ever referenced from SwiftUI views and would
    /// never even be instantiated in a session that never visits one of those screens, leaving
    /// `LocalDownloadIndex` permanently empty for playback's own download lookups.
    func reload() async {
        let records = await DownloadDatabase.shared.allRecords()
        let stats = await DownloadDatabase.shared.storageStats()
        LocalDownloadIndex.shared.replaceAll(Dictionary(uniqueKeysWithValues: records.map {
            ($0.songId, LocalDownloadIndex.Entry(path: $0.fileURL.path, format: $0.format, bitRate: $0.bitRate))
        }))
        // Assign each published property only if it actually changed: `@Published` announces
        // every assignment, and everything on screen that shows availability observes this — so
        // an unchanged reload (this runs at launch, from `PlayerManager` too, and after every
        // completed download) shouldn't re-render every row.
        if records != downloadedRecords { downloadedRecords = records }
        let ids = Set(records.map(\.songId))
        if ids != downloadedSongIds { downloadedSongIds = ids }
        if stats.totalBytes != totalBytes { totalBytes = stats.totalBytes }
        let remainingProgress = progressBySongId.filter { !downloadedSongIds.contains($0.key) }
        if remainingProgress != progressBySongId { progressBySongId = remainingProgress }
    }

    private func apply(_ update: DownloadService.Update) async {
        switch update.state {
        case .none:
            progressBySongId.removeValue(forKey: update.songId)
            failedSongIds.remove(update.songId)
        case .queued:
            progressBySongId[update.songId] = 0
        case .downloading(let progress):
            progressBySongId[update.songId] = progress
        case .completed:
            progressBySongId.removeValue(forKey: update.songId)
            failedSongIds.remove(update.songId)
            await reload()
            // A gapless-cache copy of this song, if any (in flight or already finished), is now
            // redundant — the real download always wins for playback, so it's just dead weight.
            Task { await GaplessCacheService.shared.removeIfPresent(songId: update.songId) }
        case .failed:
            progressBySongId.removeValue(forKey: update.songId)
            failedSongIds.insert(update.songId)
        }
    }
}
