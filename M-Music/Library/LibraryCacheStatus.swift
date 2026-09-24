import Foundation

/// A synchronous, `@MainActor` mirror of parts of `LibraryCacheDatabase` — exists for the same
/// reason `LocalDownloadIndex`/`GaplessCacheStatus` exist alongside their own actor-backed
/// databases: views need an instant, non-`await`-able answer to "is this available offline"
/// (cross-referencing against `DownloadStore`), and an `actor` can't offer that.
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

    private init() {}

    func songIds(forPlaylist playlistId: String) -> [String]? {
        songIdsByPlaylistId[playlistId]
    }

    func setSongIds(_ songIds: [String], forPlaylist playlistId: String) {
        songIdsByPlaylistId[playlistId] = songIds
    }

    /// Assigns the published dictionary at most once, and only if a count actually changed —
    /// per-element assignment fired `objectWillChange` (and re-rendered every list observing this)
    /// once per album, on every refetch that reported a change.
    func mergeAlbumSongCounts(_ albums: [AlbumID3]) {
        var counts = albumSongCounts
        var didChange = false
        for album in albums where counts[album.id.raw] != album.songCount {
            counts[album.id.raw] = album.songCount
            didChange = true
        }
        if didChange { albumSongCounts = counts }
    }

    func setAlbumIds(_ albumIds: [String], forArtist artistId: String) {
        albumIdsByArtistId[artistId] = albumIds
    }

    /// Every song in this album is downloaded.
    func isAlbumFullyDownloaded(albumId: String, downloads: DownloadStore) -> Bool {
        guard let totalCount = albumSongCounts[albumId], totalCount > 0 else { return false }
        let downloadedCount = downloads.downloadedRecords.lazy.filter { $0.albumId == albumId }.count
        return downloadedCount >= totalCount
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
    private var didPreload = false
    func preload() async {
        guard !didPreload else { return }
        didPreload = true
        // Read straight out of SQLite's JSON columns rather than decoding every cached playlist,
        // album and artist model — see `LibraryCacheDatabase.summary()`.
        let summary: LibraryCacheDatabase.Summary
        if let fast = await LibraryCacheDatabase.shared.summary() {
            summary = fast
        } else {
            summary = await LibraryCacheDatabase.shared.summaryByDecoding()
        }

        // Everything below runs with no suspension point, so nothing else on the main actor can
        // touch these dictionaries between reading and writing them. Each is built up in a local
        // and assigned back at most once, and only if it actually changed: mutating a `@Published`
        // dictionary element by element (as `mergeAlbumSongCounts`/`setAlbumIds` did) fires
        // `objectWillChange` for every single element — thousands of them for a real library, on
        // the main thread, right while the list screen that triggered this is opening.
        var songIds = songIdsByPlaylistId
        songIds.merge(summary.songIdsByPlaylistId) { _, new in new }
        if songIds != songIdsByPlaylistId { songIdsByPlaylistId = songIds }

        var counts = albumSongCounts
        counts.merge(summary.albumSongCounts) { _, new in new }
        if counts != albumSongCounts { albumSongCounts = counts }

        var albumIds = albumIdsByArtistId
        albumIds.merge(summary.albumIdsByArtistId) { _, new in new }
        if albumIds != albumIdsByArtistId { albumIdsByArtistId = albumIds }
    }
}
