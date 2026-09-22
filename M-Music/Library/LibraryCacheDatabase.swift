import Foundation
import GRDB

/// One generic table backs every browsing list/detail this cache needs — they're all "fetch this
/// thing from the server, store it verbatim as JSON, read it back later," so one row shape (a
/// category, a key, and a JSON blob) covers `[AlbumID3]`, `[ArtistID3]`, `[PlaylistSummary]`,
/// `[Child]`, and per-id details (`artistAlbums`, `playlistSongs`, `albumSongs`) alike, without a
/// bespoke table per entity.
private struct CachedEntry: Codable, FetchableRecord, PersistableRecord {
    var category: String
    var key: String
    var json: String
    var updatedAt: Date

    static let databaseTableName = "cached_entries"
}

/// Persists the browsing catalog (playlists, artists, albums, songs) so it's still browsable with
/// no network — mirrors `DownloadDatabase`/`GaplessCacheDatabase`'s actor+GRDB shape. Purely a
/// cache of re-fetchable server data (never the source of truth), refreshed opportunistically by
/// each screen's own fetch as a side effect of normal online browsing — there's no dedicated sync.
///
/// Lives under `Application Support`, not `Library/Caches`: the latter is something iOS can purge
/// under storage pressure with no notice, which defeats the point of this existing across
/// launches at all — the same reasoning that moved `GaplessCacheDatabase` out of `Caches` earlier,
/// and excluded from backup for the same reason that one is: easily-refetched, not worth the size.
actor LibraryCacheDatabase {
    static let shared = LibraryCacheDatabase()

    private let dbQueue: DatabaseQueue

    private init() {
        let directory = Self.rootDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        let dbURL = directory.appendingPathComponent("library.sqlite")
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
        } catch {
            dbQueue = (try? DatabaseQueue()) ?? { fatalError("Failed to open in-memory fallback database: \(error)") }()
        }
        do {
            try migrator.migrate(dbQueue)
        } catch {
            assertionFailure("LibraryCacheDatabase migration failed: \(error)")
        }
    }

    static func rootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LibraryCache", isDirectory: true)
    }

    private static func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createLibraryCache") { db in
            try db.create(table: CachedEntry.databaseTableName) { t in
                t.column("category", .text).notNull()
                t.column("key", .text).notNull()
                t.column("json", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["category", "key"])
            }
        }
        return migrator
    }

    /// The constant `key` for a category that caches one whole-catalog list rather than a
    /// per-id detail (`allAlbums`, `recentAlbums`, `allArtists`, `allPlaylists`, `allSongs`).
    static let wholeCatalogKey = "all"

    func set<T: Encodable>(_ value: T, category: String, key: String) async {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return }
        let entry = CachedEntry(category: category, key: key, json: json, updatedAt: Date())
        try? await dbQueue.write { db in
            try entry.save(db)
        }
    }

    func get<T: Decodable>(_ type: T.Type, category: String, key: String) async -> T? {
        let json: String? = try? await dbQueue.read { db in
            try CachedEntry.filter(Column("category") == category && Column("key") == key).fetchOne(db)?.json
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Drops every cached entry — e.g. when switching to a different server, where none of this
    /// would apply to the new library.
    func clearAll() async {
        try? await dbQueue.write { db in
            _ = try CachedEntry.deleteAll(db)
        }
    }

    /// Every cached playlist's song-id list, keyed by playlist id — used once, at
    /// `PlaylistsListView`'s first appearance, to preload `LibraryCacheStatus` with whatever was
    /// already cached in an earlier session, so playlists gray out correctly before any playlist
    /// is opened this session (same reasoning as `GaplessCacheService.preload()`).
    func allPlaylistSongIds() async -> [String: [String]] {
        let entries = (try? await dbQueue.read { db in
            try CachedEntry.filter(Column("category") == LibraryCacheCategory.playlistSongs).fetchAll(db)
        }) ?? []
        var result: [String: [String]] = [:]
        for entry in entries {
            guard let data = entry.json.data(using: .utf8), let songs = try? JSONDecoder().decode([Child].self, from: data)
            else { continue }
            result[entry.key] = songs.map(\.id.raw)
        }
        return result
    }

    /// Every cached artist's album list, keyed by artist id — used once, at first appearance of
    /// any of `AlbumsListView`/`ArtistsListView`/`ArtistAlbumsView`, to preload `LibraryCacheStatus`
    /// with whatever was already cached in an earlier session (same reasoning as
    /// `allPlaylistSongIds()` — without this, "is this album/artist fully downloaded" reads as
    /// false for everything until a live fetch happens to run this session, which never happens
    /// at all in an offline-only session).
    func allCachedArtistAlbums() async -> [String: [AlbumID3]] {
        let entries = (try? await dbQueue.read { db in
            try CachedEntry.filter(Column("category") == LibraryCacheCategory.artistAlbums).fetchAll(db)
        }) ?? []
        var result: [String: [AlbumID3]] = [:]
        for entry in entries {
            guard let data = entry.json.data(using: .utf8), let albums = try? JSONDecoder().decode([AlbumID3].self, from: data)
            else { continue }
            result[entry.key] = albums
        }
        return result
    }
}

/// The `category` values `CachedEntry` rows are keyed by — `allAlbums`/`recentAlbums`/
/// `allArtists`/`allPlaylists`/`allSongs` each store one whole-catalog list under
/// `LibraryCacheDatabase.wholeCatalogKey`; `artistAlbums`/`playlistSongs`/`albumSongs` store one
/// per-id detail, keyed by that artist/playlist/album's id.
private enum LibraryCacheCategory {
    static let allAlbums = "allAlbums"
    static let recentAlbums = "recentAlbums"
    static let allArtists = "allArtists"
    static let artistAlbums = "artistAlbums"
    static let allPlaylists = "allPlaylists"
    static let playlistSongs = "playlistSongs"
    static let allSongs = "allSongs"
    static let albumSongs = "albumSongs"
}

/// Thin typed wrappers around `set`/`get` — one pair per browsing screen's list/detail, so call
/// sites never touch a raw category string or JSON encoding themselves.
extension LibraryCacheDatabase {
    func cacheAllAlbums(_ albums: [AlbumID3]) async {
        await set(albums, category: LibraryCacheCategory.allAlbums, key: Self.wholeCatalogKey)
        await MainActor.run { LibraryCacheStatus.shared.mergeAlbumSongCounts(albums) }
    }

    func cachedAllAlbums() async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.allAlbums, key: Self.wholeCatalogKey)
    }

    func cacheRecentAlbums(_ albums: [AlbumID3]) async {
        await set(albums, category: LibraryCacheCategory.recentAlbums, key: Self.wholeCatalogKey)
        await MainActor.run { LibraryCacheStatus.shared.mergeAlbumSongCounts(albums) }
    }

    func cachedRecentAlbums() async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.recentAlbums, key: Self.wholeCatalogKey)
    }

    func cacheAllArtists(_ artists: [ArtistID3]) async {
        await set(artists, category: LibraryCacheCategory.allArtists, key: Self.wholeCatalogKey)
    }

    func cachedAllArtists() async -> [ArtistID3]? {
        await get([ArtistID3].self, category: LibraryCacheCategory.allArtists, key: Self.wholeCatalogKey)
    }

    func cacheArtistAlbums(_ albums: [AlbumID3], artistId: String) async {
        await set(albums, category: LibraryCacheCategory.artistAlbums, key: artistId)
        await MainActor.run {
            LibraryCacheStatus.shared.mergeAlbumSongCounts(albums)
            LibraryCacheStatus.shared.setAlbumIds(albums.map { $0.id.raw }, forArtist: artistId)
        }
    }

    func cachedArtistAlbums(artistId: String) async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.artistAlbums, key: artistId)
    }

    func cacheAllPlaylists(_ playlists: [PlaylistSummary]) async {
        await set(playlists, category: LibraryCacheCategory.allPlaylists, key: Self.wholeCatalogKey)
    }

    func cachedAllPlaylists() async -> [PlaylistSummary]? {
        await get([PlaylistSummary].self, category: LibraryCacheCategory.allPlaylists, key: Self.wholeCatalogKey)
    }

    /// Also mirrors the song-id list into `LibraryCacheStatus` so `PlaylistsListView` can gray
    /// out this playlist immediately, without waiting on a fresh actor round-trip.
    func cachePlaylistSongs(_ songs: [Child], playlistId: String) async {
        await set(songs, category: LibraryCacheCategory.playlistSongs, key: playlistId)
        let songIds = songs.map(\.id.raw)
        await MainActor.run { LibraryCacheStatus.shared.setSongIds(songIds, forPlaylist: playlistId) }
    }

    func cachedPlaylistSongs(playlistId: String) async -> [Child]? {
        await get([Child].self, category: LibraryCacheCategory.playlistSongs, key: playlistId)
    }

    func cacheAllSongs(_ songs: [Child]) async {
        await set(songs, category: LibraryCacheCategory.allSongs, key: Self.wholeCatalogKey)
    }

    func cachedAllSongs() async -> [Child]? {
        await get([Child].self, category: LibraryCacheCategory.allSongs, key: Self.wholeCatalogKey)
    }

    func cacheAlbumSongs(_ album: AlbumWithSongsID3, albumId: String) async {
        await set(album, category: LibraryCacheCategory.albumSongs, key: albumId)
    }

    func cachedAlbumSongs(albumId: String) async -> AlbumWithSongsID3? {
        await get(AlbumWithSongsID3.self, category: LibraryCacheCategory.albumSongs, key: albumId)
    }
}
