import Foundation

/// A synchronous, `@MainActor` mirror of parts of `LibraryCacheDatabase` — exists for the same
/// reason `LocalDownloadIndex`/`GaplessCacheStatus` exist alongside their own actor-backed
/// databases: views need an instant, non-`await`-able answer to "is this available offline"
/// (cross-referencing against `DownloadStore`), and an `actor` can't offer that.
///
/// It is only ever a *read-only view* of `LibraryCacheIndex`, which owns the data: every merge,
/// id mapping and "did anything change?" comparison happens there, off the main actor, and this
/// class just receives the finished dictionaries (`apply`) — assigning a dictionary is O(1), while
/// merging and diffing them on the main thread scaled with the size of the whole library.
@MainActor
final class LibraryCacheStatus: ObservableObject {
    static let shared = LibraryCacheStatus()

    @Published private(set) var songIdsByPlaylistId: [String: [String]] = [:]
    /// Each album's total track count, mirrored in whenever its `AlbumID3` is cached/fetched
    /// anywhere (`LibraryCacheDatabase.cacheAllAlbums`/`cacheRecentAlbums`/`cacheArtistAlbums`) —
    /// `DownloadRecord` alone only tells us how many of an album's songs are downloaded, never
    /// how many it actually has, so "fully downloaded" needs this too.
    @Published private(set) var albumSongCounts: [String: Int] = [:]
    /// Each artist's album ids, mirrored in whenever `cacheArtistAlbums` runs.
    @Published private(set) var albumIdsByArtistId: [String: [String]] = [:]
    /// Bumped whenever any of the above changed. Views that only need to know "did the cache
    /// status change?" observe this with `.onChange` instead of the dictionaries themselves, so
    /// SwiftUI doesn't diff whole dictionaries on the main thread every time one is published.
    @Published private(set) var revision = 0

    private init() {}

    func songIds(forPlaylist playlistId: String) -> [String]? {
        songIdsByPlaylistId[playlistId]
    }

    /// Assigns whichever dictionaries the background index reports as changed.
    func apply(_ update: LibraryCacheIndex.Update) {
        if let songIds = update.songIdsByPlaylistId { songIdsByPlaylistId = songIds }
        if let counts = update.albumSongCounts { albumSongCounts = counts }
        if let albumIds = update.albumIdsByArtistId { albumIdsByArtistId = albumIds }
        revision &+= 1
    }

    /// Every song in this album is downloaded.
    func isAlbumFullyDownloaded(albumId: String, downloads: DownloadStore) -> Bool {
        guard let totalCount = albumSongCounts[albumId], totalCount > 0 else { return false }
        return downloads.downloadedSongCount(inAlbum: albumId) >= totalCount
    }

    /// At least one of this artist's albums (any release type/version) is fully downloaded.
    func hasFullyDownloadedAlbum(artistId: String, downloads: DownloadStore) -> Bool {
        (albumIdsByArtistId[artistId] ?? []).contains { isAlbumFullyDownloaded(albumId: $0, downloads: downloads) }
    }

    /// Loads everything previously cached (playlist song-id lists, the whole album catalog, and
    /// every artist's album list) — called once, lazily, from the first appearance of any of
    /// `PlaylistsListView`/`AlbumsListView`/`ArtistsListView`/`ArtistAlbumsView`, so offline
    /// availability reads correctly before anything's been fetched live this session. Without
    /// this, `albumSongCounts`/`albumIdsByArtistId` only ever got populated as a side effect of a
    /// live fetch succeeding — meaning "is this fully downloaded" read as `false` for everything
    /// in a session that starts offline, even though the answer was already sitting on disk.
    ///
    /// `nonisolated`: the work is entirely on `LibraryCacheIndex`, so calling this doesn't even
    /// touch the main actor.
    nonisolated func preload() async {
        await LibraryCacheIndex.shared.preload()
    }
}

/// Owns the offline-availability data behind `LibraryCacheStatus` and does all of the work of
/// keeping it current — merging fetched albums into the per-album counts, mapping ids, reading the
/// cached summary at launch, and comparing old against new — on a background executor.
///
/// Updates arrive in bursts (the connect-time sync caches one artist at a time, hundreds of
/// times), so changes are coalesced: the first change after a publish schedules one publish a
/// short debounce later, and everything that lands meanwhile rides along with it, rather than one
/// main-actor hop and one `@Published` change per cached entry.
actor LibraryCacheIndex {
    static let shared = LibraryCacheIndex()

    /// Which dictionaries changed since the last publish; `nil` = unchanged.
    struct Update: Sendable, Equatable {
        var songIdsByPlaylistId: [String: [String]]?
        var albumSongCounts: [String: Int]?
        var albumIdsByArtistId: [String: [String]]?
    }

    private var songIdsByPlaylistId: [String: [String]] = [:]
    private var albumSongCounts: [String: Int] = [:]
    private var albumIdsByArtistId: [String: [String]] = [:]

    private var dirtySongIds = false
    private var dirtyCounts = false
    private var dirtyAlbumIds = false

    private var publishTask: Task<Void, Never>?
    private var didPreload = false

    private let debounce: Duration
    private let publish: @Sendable (Update) async -> Void

    init(
        debounce: Duration = .milliseconds(100),
        publish: @escaping @Sendable (Update) async -> Void = { update in
            await MainActor.run { LibraryCacheStatus.shared.apply(update) }
        }
    ) {
        self.debounce = debounce
        self.publish = publish
    }

    func setSongIds(_ songIds: [String], forPlaylist playlistId: String) {
        guard songIdsByPlaylistId[playlistId] != songIds else { return }
        songIdsByPlaylistId[playlistId] = songIds
        dirtySongIds = true
        schedulePublish()
    }

    func setAlbumIds(_ albumIds: [String], forArtist artistId: String) {
        guard albumIdsByArtistId[artistId] != albumIds else { return }
        albumIdsByArtistId[artistId] = albumIds
        dirtyAlbumIds = true
        schedulePublish()
    }

    /// Records each album's track count; only counts that actually differ mark anything changed.
    func mergeAlbumSongCounts(_ albums: [AlbumID3]) {
        var changed = false
        for album in albums where albumSongCounts[album.id.raw] != album.songCount {
            albumSongCounts[album.id.raw] = album.songCount
            changed = true
        }
        if changed {
            dirtyCounts = true
            schedulePublish()
        }
    }

    /// Loads what an earlier session cached — read straight out of SQLite's JSON columns rather
    /// than decoding every cached playlist, album and artist model (see
    /// `LibraryCacheDatabase.summary()`), then merged and diffed here, off the main actor.
    func preload() async {
        guard !didPreload else { return }
        didPreload = true
        let summary: LibraryCacheDatabase.Summary
        if let fast = await LibraryCacheDatabase.shared.summary() {
            summary = fast
        } else {
            summary = await LibraryCacheDatabase.shared.summaryByDecoding()
        }
        merge(summary)
    }

    func merge(_ summary: LibraryCacheDatabase.Summary) {
        var songIds = songIdsByPlaylistId
        songIds.merge(summary.songIdsByPlaylistId) { _, new in new }
        if songIds != songIdsByPlaylistId {
            songIdsByPlaylistId = songIds
            dirtySongIds = true
        }

        var counts = albumSongCounts
        counts.merge(summary.albumSongCounts) { _, new in new }
        if counts != albumSongCounts {
            albumSongCounts = counts
            dirtyCounts = true
        }

        var albumIds = albumIdsByArtistId
        albumIds.merge(summary.albumIdsByArtistId) { _, new in new }
        if albumIds != albumIdsByArtistId {
            albumIdsByArtistId = albumIds
            dirtyAlbumIds = true
        }
        if dirtySongIds || dirtyCounts || dirtyAlbumIds { schedulePublish() }
    }

    /// Publishes immediately whatever is pending (used by tests, and to settle before reading).
    func flush() async {
        publishTask?.cancel()
        publishTask = nil
        await publishPending()
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.publishTask = nil
            await self.publishPending()
        }
    }

    private func publishPending() async {
        guard dirtySongIds || dirtyCounts || dirtyAlbumIds else { return }
        let update = Update(
            songIdsByPlaylistId: dirtySongIds ? songIdsByPlaylistId : nil,
            albumSongCounts: dirtyCounts ? albumSongCounts : nil,
            albumIdsByArtistId: dirtyAlbumIds ? albumIdsByArtistId : nil
        )
        dirtySongIds = false
        dirtyCounts = false
        dirtyAlbumIds = false
        await publish(update)
    }
}
