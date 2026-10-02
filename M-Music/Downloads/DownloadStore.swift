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
    /// Bumped whenever the downloaded set changed. Views that only need "did the downloads
    /// change?" observe this with `.onChange` instead of `downloadedSongIds`, so SwiftUI doesn't
    /// diff the whole set on the main thread each time it's published.
    @Published private(set) var revision = 0

    // Derived lookups from the latest `DownloadSnapshot`, built off the main actor. Not
    // `@Published`: they only ever change together with `downloadedRecords`, which is.
    private(set) var recordsByAlbum: [DownloadSnapshot.AlbumGroup] = []
    private var songCountByAlbumId: [String: Int] = [:]
    private var artistNames: Set<String> = []
    private var snapshot = DownloadSnapshot()
    private var reloadTask: Task<Void, Never>?
    private var reloadRequested = false

    private var failedSongIds: Set<String> = []
    private var updateObservationTask: Task<Void, Never>?

    private init() {
        // The very first `DownloadDatabase.shared` access creates and migrates the SQLite file
        // (on a fresh install: directory creation, `sqlite3_open`, migrations with an fsync each).
        // That's a synchronous static initializer that runs on whatever thread touches it first —
        // which, from this `@MainActor` class's `reload()`, was the main thread, during launch.
        // Touch it here from a background task first, so `reload()` finds it already built.
        Task.detached(priority: .utility) { [weak self] in
            _ = DownloadDatabase.shared
            await self?.reload()
        }
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
        return songCountByAlbumId[albumId, default: 0] > 0
    }

    /// How many of `albumId`'s songs are downloaded.
    func downloadedSongCount(inAlbum albumId: String) -> Int {
        songCountByAlbumId[albumId, default: 0]
    }

    /// Whether any downloaded song's `artist` field matches `artistName` — the only signal
    /// available for this without a heavier artist-id lookup, since `DownloadRecord` only ever
    /// stores the artist's name (the same string `ArtistID3.name` uses), not an id.
    func hasDownloadedSong(byArtist artistName: String?) -> Bool {
        guard let artistName else { return false }
        return artistNames.contains(artistName)
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
    ///
    /// Reading the database, deriving the lookups and diffing against the previous state all run
    /// off the main actor (`DownloadSnapshot.load`); this only assigns what changed. Overlapping
    /// requests are coalesced — a download that completes while a reload is running (an album's
    /// worth arrive back to back) just asks for one more pass instead of starting its own — and
    /// every caller returns once a pass that started after its request has finished.
    func reload() async {
        if let reloadTask {
            reloadRequested = true
            await reloadTask.value
            return
        }
        let task = Task { [self] in
            repeat {
                reloadRequested = false
                await performReload()
            } while reloadRequested
            // No suspension between the loop's last check and clearing the task, so a request can
            // never slip in between and be dropped.
            reloadTask = nil
        }
        reloadTask = task
        await task.value
    }

    private func performReload() async {
        guard let (new, changes) = await DownloadSnapshot.load(previous: snapshot) else {
            dropStaleProgress()
            return
        }
        snapshot = new
        // Assign each published property only if it actually changed: `@Published` announces
        // every assignment, and everything on screen that shows availability observes this — so
        // an unchanged reload (this runs at launch, from `PlayerManager` too, and after every
        // completed download) shouldn't re-render every row.
        if changes.records {
            recordsByAlbum = new.recordsByAlbum
            songCountByAlbumId = new.songCountByAlbumId
            artistNames = new.artistNames
            downloadedRecords = new.records
        }
        if changes.songIds { downloadedSongIds = new.songIds }
        if changes.totalBytes { totalBytes = new.totalBytes }
        if changes.records || changes.songIds { revision &+= 1 }
        // The downloads changed — or this is the first load of a launch that has some — so make
        // sure all their artwork is saved in the permanent cache. Cheap when nothing's missing.
        if changes.records && !new.records.isEmpty {
            Task(priority: .utility) { await DownloadedArtwork.shared.requestSync() }
        }
        dropStaleProgress()
    }

    private func dropStaleProgress() {
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
