import Foundation
import GRDB

/// SQLite-backed catalog of downloaded songs, via GRDB — a deliberately small slice of Shelv's
/// `DownloadDatabase.swift` (no multi-server tables, playlist markers, or CloudKit hooks; M-Music
/// talks to a single server and downloads individual songs/albums only).
actor DownloadDatabase {
    static let shared = DownloadDatabase()

    private let dbQueue: DatabaseQueue

    private init() {
        let directory = Self.rootDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("downloads.sqlite")
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
        } catch {
            // Falling back to an in-memory database keeps the app usable (downloads just won't
            // persist across launches) instead of crashing if the on-disk file can't be opened.
            dbQueue = (try? DatabaseQueue()) ?? { fatalError("Failed to open in-memory fallback database: \(error)") }()
        }
        do {
            try migrator.migrate(dbQueue)
        } catch {
            assertionFailure("DownloadDatabase migration failed: \(error)")
        }
    }

    static func rootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createDownloads") { db in
            try db.create(table: DownloadRecord.databaseTableName) { t in
                t.column("songId", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("albumId", .text).indexed()
                t.column("coverArt", .text)
                t.column("track", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("filePath", .text).notNull()
                t.column("fileExtension", .text).notNull()
                t.column("contentType", .text)
                t.column("bitRate", .integer)
                t.column("byteSize", .integer).notNull()
                t.column("replayGainTrackGain", .double)
                t.column("replayGainAlbumGain", .double)
                t.column("addedAt", .datetime).notNull()
            }
        }
        return migrator
    }

    func upsert(_ record: DownloadRecord) async {
        try? await dbQueue.write { db in
            try record.save(db)
        }
    }

    func delete(songId: String) async {
        try? await dbQueue.write { db in
            _ = try DownloadRecord.deleteOne(db, key: songId)
        }
    }

    func delete(songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        try? await dbQueue.write { db in
            _ = try DownloadRecord.deleteAll(db, keys: songIds)
        }
    }

    func record(songId: String) async -> DownloadRecord? {
        (try? await dbQueue.read { db in
            try DownloadRecord.fetchOne(db, key: songId)
        }) ?? nil
    }

    func allRecords() async -> [DownloadRecord] {
        (try? await dbQueue.read { db in
            try DownloadRecord.order(Column("addedAt").desc).fetchAll(db)
        }) ?? []
    }

    func records(albumId: String) async -> [DownloadRecord] {
        (try? await dbQueue.read { db in
            try DownloadRecord.filter(Column("albumId") == albumId).fetchAll(db)
        }) ?? []
    }

    func storageStats() async -> DownloadStorageStats {
        (try? await dbQueue.read { db in
            let totalBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM downloads") ?? 0
            let songCount = try DownloadRecord.fetchCount(db)
            let albumCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(DISTINCT albumId) FROM downloads WHERE albumId IS NOT NULL"
            ) ?? 0
            return DownloadStorageStats(totalBytes: totalBytes, songCount: songCount, albumCount: albumCount)
        }) ?? DownloadStorageStats(totalBytes: 0, songCount: 0, albumCount: 0)
    }
}
