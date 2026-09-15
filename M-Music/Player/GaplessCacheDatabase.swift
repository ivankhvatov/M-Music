import Foundation
import GRDB

/// SQLite-backed catalog of `GaplessCacheService`'s cached tracks, via GRDB — mirrors
/// `DownloadDatabase`'s shape and, like it, lives under `Application Support` rather than
/// `Library/Caches`. It was originally placed under `Library/Caches` on the reasoning that this
/// data is disposable — but that directory is also one iOS can silently purge under storage
/// pressure at any time, with no notice to the app, which defeats the entire point of this cache
/// having its own user-configured size limit and retention window (`GaplessCacheSettings`): the
/// app's own policy should be the only thing that decides when an entry goes away. Marked
/// excluded from backup below instead, to get `Application Support`'s durability without also
/// bloating someone's device backup with easily-refetched data.
actor GaplessCacheDatabase {
    static let shared = GaplessCacheDatabase()

    private let dbQueue: DatabaseQueue

    private init() {
        let directory = Self.rootDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        let dbURL = directory.appendingPathComponent("cache.sqlite")
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
        } catch {
            dbQueue = (try? DatabaseQueue()) ?? { fatalError("Failed to open in-memory fallback database: \(error)") }()
        }
        do {
            try migrator.migrate(dbQueue)
        } catch {
            assertionFailure("GaplessCacheDatabase migration failed: \(error)")
        }
    }

    static func rootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GaplessCache", isDirectory: true)
    }

    private static func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createGaplessCache") { db in
            try db.create(table: GaplessCacheRecord.databaseTableName) { t in
                t.column("songId", .text).primaryKey()
                t.column("format", .text).notNull()
                t.column("bitrate", .integer).notNull()
                t.column("filePath", .text).notNull()
                t.column("fileExtension", .text).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("cachedAt", .datetime).notNull()
                t.column("lastPlayedAt", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("albumId", .text)
            }
        }
        return migrator
    }

    func upsert(_ record: GaplessCacheRecord) async {
        try? await dbQueue.write { db in
            try record.save(db)
        }
    }

    func touch(songId: String, at date: Date = Date()) async {
        try? await dbQueue.write { db in
            try db.execute(sql: "UPDATE gapless_cache SET lastPlayedAt = ? WHERE songId = ?", arguments: [date, songId])
        }
    }

    func delete(songId: String) async {
        try? await dbQueue.write { db in
            _ = try GaplessCacheRecord.deleteOne(db, key: songId)
        }
    }

    /// Deletes every cached row. Returns the deleted records so the caller can remove their
    /// files from disk.
    func deleteAll() async -> [GaplessCacheRecord] {
        (try? await dbQueue.write { db in
            let all = try GaplessCacheRecord.fetchAll(db)
            try GaplessCacheRecord.deleteAll(db)
            return all
        }) ?? []
    }

    func record(songId: String) async -> GaplessCacheRecord? {
        (try? await dbQueue.read { db in
            try GaplessCacheRecord.fetchOne(db, key: songId)
        }) ?? nil
    }

    func allRecords() async -> [GaplessCacheRecord] {
        (try? await dbQueue.read { db in
            try GaplessCacheRecord.fetchAll(db)
        }) ?? []
    }

    func totalBytes() async -> Int64 {
        (try? await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM gapless_cache") ?? 0
        }) ?? 0
    }

    /// Deletes least-recently-played rows until the total cached size is back under `maxBytes`.
    /// Returns the deleted records so the caller can remove their files from disk.
    func evictOverBudget(maxBytes: Int64) async -> [GaplessCacheRecord] {
        (try? await dbQueue.write { db in
            var records = try GaplessCacheRecord.order(Column("lastPlayedAt").asc).fetchAll(db)
            var total = records.reduce(Int64(0)) { $0 + $1.byteSize }
            var evicted: [GaplessCacheRecord] = []
            while total > maxBytes, !records.isEmpty {
                let oldest = records.removeFirst()
                try oldest.delete(db)
                total -= oldest.byteSize
                evicted.append(oldest)
            }
            return evicted
        }) ?? []
    }

    /// Deletes rows not played since before `cutoff`. Returns the deleted records so the caller
    /// can remove their files from disk.
    func evictOlderThan(_ cutoff: Date) async -> [GaplessCacheRecord] {
        (try? await dbQueue.write { db in
            let stale = try GaplessCacheRecord.filter(Column("lastPlayedAt") < cutoff).fetchAll(db)
            try GaplessCacheRecord.filter(Column("lastPlayedAt") < cutoff).deleteAll(db)
            return stale
        }) ?? []
    }
}
