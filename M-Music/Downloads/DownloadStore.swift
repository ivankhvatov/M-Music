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
        downloadedRecords = records
        downloadedSongIds = Set(records.map(\.songId))
        totalBytes = stats.totalBytes
        progressBySongId = progressBySongId.filter { !downloadedSongIds.contains($0.key) }
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
