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

    func mergeAlbumSongCounts(_ albums: [AlbumID3]) {
        for album in albums { albumSongCounts[album.id.raw] = album.songCount }
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
        let byPlaylistId = await LibraryCacheDatabase.shared.allPlaylistSongIds()
        let allAlbums = await LibraryCacheDatabase.shared.cachedAllAlbums()
        let byArtistId = await LibraryCacheDatabase.shared.allCachedArtistAlbums()

        // Everything below runs with no suspension point, so nothing else on the main actor can
        // touch these dictionaries between reading and writing them. Each is built up in a local
        // and assigned back exactly once: mutating a `@Published` dictionary element by element
        // (as `mergeAlbumSongCounts`/`setAlbumIds` do for their incremental callers) fires
        // `objectWillChange` for every single element — thousands of them for a real library,
        // on the main thread, right while the list screen that triggered this is opening.
        var songIds = songIdsByPlaylistId
        songIds.merge(byPlaylistId) { _, new in new }

        var counts = albumSongCounts
        for album in allAlbums ?? [] { counts[album.id.raw] = album.songCount }

        var albumIds = albumIdsByArtistId
        for (artistId, albums) in byArtistId {
            for album in albums { counts[album.id.raw] = album.songCount }
            albumIds[artistId] = albums.map { $0.id.raw }
        }

        songIdsByPlaylistId = songIds
        albumSongCounts = counts
        albumIdsByArtistId = albumIds
    }
}
