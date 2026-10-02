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

    /// `nonisolated`: `DatabaseQueue` is thread-safe and serialises the SQL itself, so `get`/`set`
    /// below don't need the actor — which means the (potentially large) JSON encode/decode they do
    /// runs on the *caller's* background task, in parallel, instead of queuing every cache read
    /// behind every other read and write on this actor.
    private nonisolated let dbQueue: DatabaseQueue

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

    /// Already-decoded entries, so reopening a screen doesn't re-decode the whole catalog. Every
    /// open of Songs, Albums or Artists used to parse the full cached JSON again (tens of
    /// thousands of `Child`s, ~28 `decodeIfPresent` calls each) on a background core — seconds of
    /// CPU per open at a large library's size. An `NSCache` rather than a dictionary because a
    /// decoded 50k-song list is tens of MB in an app that also plays audio in the background: it
    /// evicts under memory pressure. Every write path below (`set`, `remove`, `clearAll`)
    /// invalidates it, so a hit is always what the database holds.
    private final class DecodedEntry {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    private static let decodedCache: NSCache<NSString, DecodedEntry> = {
        let cache = NSCache<NSString, DecodedEntry>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(category: String, key: String) -> NSString {
        "\(category)\u{1F}\(key)" as NSString
    }

    nonisolated func set<T: Encodable>(_ value: T, category: String, key: String) async {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return }
        let entry = CachedEntry(category: category, key: key, json: json, updatedAt: Date())
        Self.decodedCache.removeObject(forKey: Self.cacheKey(category: category, key: key))
        try? await dbQueue.write { db in
            try entry.save(db)
        }
        // Again after the write: a read that started before it could have re-filled the cache
        // with the old value in between.
        Self.decodedCache.removeObject(forKey: Self.cacheKey(category: category, key: key))
    }

    nonisolated func remove(category: String, key: String) async {
        Self.decodedCache.removeObject(forKey: Self.cacheKey(category: category, key: key))
        try? await dbQueue.write { db in
            _ = try CachedEntry.filter(Column("category") == category && Column("key") == key).deleteAll(db)
        }
        Self.decodedCache.removeObject(forKey: Self.cacheKey(category: category, key: key))
    }

    nonisolated func get<T: Decodable>(_ type: T.Type, category: String, key: String) async -> T? {
        let cacheKey = Self.cacheKey(category: category, key: key)
        if let cached = Self.decodedCache.object(forKey: cacheKey)?.value as? T { return cached }
        let json: String? = try? await dbQueue.read { db in
            try CachedEntry.filter(Column("category") == category && Column("key") == key).fetchOne(db)?.json
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        Self.decodedCache.setObject(DecodedEntry(decoded), forKey: cacheKey, cost: data.count * 3)
        return decoded
    }

    /// Drops every cached entry — e.g. when switching to a different server, where none of this
    /// would apply to the new library.
    func clearAll() async {
        Self.decodedCache.removeAllObjects()
        try? await dbQueue.write { db in
            _ = try CachedEntry.deleteAll(db)
        }
        Self.decodedCache.removeAllObjects()
        // The tokens record "this list is synced as of scan X" — meaningless once the cached
        // list itself is gone.
        await LibraryRevalidation.shared.reset()
    }

    /// What `LibraryCacheStatus` needs out of the cache, and nothing more: which songs each cached
    /// playlist has, how many songs each cached album has, and which albums each cached artist has.
    struct Summary: Sendable {
        var songIdsByPlaylistId: [String: [String]] = [:]
        var albumSongCounts: [String: Int] = [:]
        var albumIdsByArtistId: [String: [String]] = [:]
    }

    /// Builds `Summary` with SQLite's own JSON functions (`json_each`/`json_extract`) rather than
    /// decoding every cached playlist's full `[Child]`, the whole album catalog and every
    /// artist's `[AlbumID3]` through `Codable` just to keep a few fields of each — the SQLite
    /// parser does the same job at C speed with no model objects allocated. IDs are plain
    /// strings in the stored JSON (`FlexibleID` encodes as one). Returns `nil` if the query
    /// fails for any reason, so the caller can fall back to `summaryByDecoding()`.
    func summary() async -> Summary? {
        try? await dbQueue.read { db in
            var summary = Summary()

            let playlistRows = try Row.fetchCursor(db, sql: """
                SELECT c.key AS ownerKey, json_extract(s.value, '$.id') AS itemId
                FROM cached_entries AS c, json_each(c.json) AS s
                WHERE c.category = ? AND json_valid(c.json)
                """, arguments: [LibraryCacheCategory.playlistSongs])
            while let row = try playlistRows.next() {
                guard let playlistId: String = row["ownerKey"], let songId: String = row["itemId"] else { continue }
                summary.songIdsByPlaylistId[playlistId, default: []].append(songId)
            }

            let catalogRows = try Row.fetchCursor(db, sql: """
                SELECT json_extract(a.value, '$.id') AS itemId, json_extract(a.value, '$.songCount') AS songCount
                FROM cached_entries AS c, json_each(c.json) AS a
                WHERE c.category = ? AND c.key = ? AND json_valid(c.json)
                """, arguments: [LibraryCacheCategory.allAlbums, LibraryCacheDatabase.wholeCatalogKey])
            while let row = try catalogRows.next() {
                guard let albumId: String = row["itemId"], let songCount: Int = row["songCount"] else { continue }
                summary.albumSongCounts[albumId] = songCount
            }

            let artistRows = try Row.fetchCursor(db, sql: """
                SELECT c.key AS ownerKey, json_extract(a.value, '$.id') AS itemId, json_extract(a.value, '$.songCount') AS songCount
                FROM cached_entries AS c, json_each(c.json) AS a
                WHERE c.category = ? AND json_valid(c.json)
                """, arguments: [LibraryCacheCategory.artistAlbums])
            while let row = try artistRows.next() {
                guard let artistId: String = row["ownerKey"], let albumId: String = row["itemId"] else { continue }
                summary.albumIdsByArtistId[artistId, default: []].append(albumId)
                if let songCount: Int = row["songCount"] {
                    summary.albumSongCounts[albumId] = songCount
                }
            }

            return summary
        }
    }

    /// The ids of the cached playlists that contain at least one of `songIds` — read with SQLite's
    /// own JSON functions, like `summary()`, so no playlist's song list is decoded. Used to find
    /// the playlists whose artwork belongs in the permanent cache (those with a downloaded song).
    nonisolated func playlistIds(containingAnyOf songIds: Set<String>) async -> Set<String> {
        guard !songIds.isEmpty else { return [] }
        let found: Set<String>? = try? await dbQueue.read { db in
            var found = Set<String>()
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.key AS ownerKey, json_extract(s.value, '$.id') AS itemId
                FROM cached_entries AS c, json_each(c.json) AS s
                WHERE c.category = ? AND json_valid(c.json)
                """, arguments: [LibraryCacheCategory.playlistSongs])
            while let row = try rows.next() {
                guard let playlistId: String = row["ownerKey"], !found.contains(playlistId),
                      let songId: String = row["itemId"], songIds.contains(songId)
                else { continue }
                found.insert(playlistId)
            }
            return found
        }
        return found ?? []
    }

    /// The same `Summary`, built the slow way — full `Codable` decodes of every relevant cached
    /// entry. Only used if `summary()` fails.
    func summaryByDecoding() async -> Summary {
        var summary = Summary()
        summary.songIdsByPlaylistId = await allPlaylistSongIds()
        for album in await cachedAllAlbums() ?? [] {
            summary.albumSongCounts[album.id.raw] = album.songCount
        }
        for (artistId, albums) in await allCachedArtistAlbums() {
            for album in albums { summary.albumSongCounts[album.id.raw] = album.songCount }
            summary.albumIdsByArtistId[artistId] = albums.map { $0.id.raw }
        }
        return summary
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
    nonisolated func cacheAllAlbums(_ albums: [AlbumID3]) async {
        await set(albums, category: LibraryCacheCategory.allAlbums, key: Self.wholeCatalogKey)
        await LibraryCacheIndex.shared.mergeAlbumSongCounts(albums)
    }

    nonisolated func cachedAllAlbums() async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.allAlbums, key: Self.wholeCatalogKey)
    }

    nonisolated func cacheRecentAlbums(_ albums: [AlbumID3]) async {
        await set(albums, category: LibraryCacheCategory.recentAlbums, key: Self.wholeCatalogKey)
        await LibraryCacheIndex.shared.mergeAlbumSongCounts(albums)
    }

    nonisolated func cachedRecentAlbums() async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.recentAlbums, key: Self.wholeCatalogKey)
    }

    nonisolated func cacheAllArtists(_ artists: [ArtistID3]) async {
        await set(artists, category: LibraryCacheCategory.allArtists, key: Self.wholeCatalogKey)
    }

    nonisolated func cachedAllArtists() async -> [ArtistID3]? {
        await get([ArtistID3].self, category: LibraryCacheCategory.allArtists, key: Self.wholeCatalogKey)
    }

    nonisolated func cacheArtistAlbums(_ albums: [AlbumID3], artistId: String) async {
        await set(albums, category: LibraryCacheCategory.artistAlbums, key: artistId)
        await LibraryCacheIndex.shared.mergeAlbumSongCounts(albums)
        await LibraryCacheIndex.shared.setAlbumIds(albums.map { $0.id.raw }, forArtist: artistId)
    }

    nonisolated func cachedArtistAlbums(artistId: String) async -> [AlbumID3]? {
        await get([AlbumID3].self, category: LibraryCacheCategory.artistAlbums, key: artistId)
    }

    nonisolated func cacheAllPlaylists(_ playlists: [PlaylistSummary]) async {
        await set(playlists, category: LibraryCacheCategory.allPlaylists, key: Self.wholeCatalogKey)
        // A playlist's cover may have changed.
        await DownloadedArtwork.shared.requestSync()
    }

    nonisolated func cachedAllPlaylists() async -> [PlaylistSummary]? {
        await get([PlaylistSummary].self, category: LibraryCacheCategory.allPlaylists, key: Self.wholeCatalogKey)
    }

    /// Also mirrors the song-id list into `LibraryCacheStatus` so `PlaylistsListView` can gray
    /// out this playlist immediately, without waiting on a fresh actor round-trip.
    nonisolated func cachePlaylistSongs(_ songs: [Child], playlistId: String) async {
        await set(songs, category: LibraryCacheCategory.playlistSongs, key: playlistId)
        await LibraryCacheIndex.shared.setSongIds(songs.map(\.id.raw), forPlaylist: playlistId)
        // The playlist may now contain a downloaded song.
        await DownloadedArtwork.shared.requestSync()
    }

    nonisolated func cachedPlaylistSongs(playlistId: String) async -> [Child]? {
        await get([Child].self, category: LibraryCacheCategory.playlistSongs, key: playlistId)
    }

    nonisolated func cacheAllSongs(_ songs: [Child]) async {
        await set(songs, category: LibraryCacheCategory.allSongs, key: Self.wholeCatalogKey)
    }

    nonisolated func cachedAllSongs() async -> [Child]? {
        await get([Child].self, category: LibraryCacheCategory.allSongs, key: Self.wholeCatalogKey)
    }

    nonisolated func cacheAlbumSongs(_ album: AlbumWithSongsID3, albumId: String) async {
        await set(album, category: LibraryCacheCategory.albumSongs, key: albumId)
    }

    /// An artist's albums that are downloaded in full, for browsing offline: the album metadata
    /// comes from the cached artist album list (falling back to the cached whole-album catalog),
    /// since `DownloadRecord` doesn't know how many songs an album actually has — and "fully
    /// downloaded" needs that. Runs entirely off the main actor.
    nonisolated func fullyDownloadedAlbums(byArtist artistId: String) async -> [AlbumID3] {
        let candidates: [AlbumID3]
        if let cached = await cachedArtistAlbums(artistId: artistId) {
            candidates = cached
        } else {
            candidates = (await cachedAllAlbums() ?? []).filter { $0.artistId?.raw == artistId }
        }
        guard !candidates.isEmpty else { return [] }
        let downloadedCounts = await DownloadDatabase.shared.downloadedSongCountsByAlbumId()
        return candidates.filter { album in
            album.songCount > 0 && downloadedCounts[album.id.raw, default: 0] >= album.songCount
        }
    }

    nonisolated func removeCachedAlbumSongs(albumId: String) async {
        await remove(category: LibraryCacheCategory.albumSongs, key: albumId)
    }

    nonisolated func cachedAlbumSongs(albumId: String) async -> AlbumWithSongsID3? {
        await get(AlbumWithSongsID3.self, category: LibraryCacheCategory.albumSongs, key: albumId)
    }
}
