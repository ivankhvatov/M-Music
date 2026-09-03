import Foundation

/// Cache for `getAlbum` results, keyed by album id — in-memory for the running session, and
/// mirrored to disk (under Caches/SubsonicAlbumCache) so it survives relaunches too.
///
/// `SubsonicClient` itself never caches (see its design notes) so callers that need fresh
/// data can always call `getAlbum` directly. `AlbumView` goes through this cache instead so
/// reopening an album it (or a previous session) has already loaded shows the track list
/// instantly instead of re-fetching it.
final class AlbumDetailsCache: @unchecked Sendable {
    static let shared = AlbumDetailsCache()

    private let client: SubsonicClient
    private let fileManager = FileManager.default
    private let directory: URL?

    private let lock = NSLock()
    private var albums: [String: AlbumWithSongsID3] = [:]

    init(client: SubsonicClient = .shared) {
        self.client = client
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("SubsonicAlbumCache", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
        } else {
            directory = nil
        }
    }

    /// Returns the cached album if we have it (in memory, or on disk from a previous
    /// session), otherwise fetches it via `SubsonicClient.getAlbum(id:)` and caches the result
    /// both in memory and on disk for next time.
    func album(id: String) async throws -> AlbumWithSongsID3 {
        if let cached = memoryAlbum(forId: id) {
            return cached
        }
        if let onDisk = diskAlbum(forId: id) {
            setMemoryAlbum(onDisk, forId: id)
            return onDisk
        }
        let album = try await client.getAlbum(id: id)
        setMemoryAlbum(album, forId: id)
        writeToDisk(album, id: id)
        return album
    }

    /// Drops one cached entry (memory and disk), e.g. after an edit that could change its track list.
    func invalidate(id: String) {
        lock.lock()
        albums.removeValue(forKey: id)
        lock.unlock()
        if let url = fileURL(forId: id) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Drops every cached entry (memory and disk), e.g. when switching to a different server.
    func invalidateAll() {
        lock.lock()
        albums.removeAll()
        lock.unlock()
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - In-memory layer

    private func memoryAlbum(forId id: String) -> AlbumWithSongsID3? {
        lock.lock(); defer { lock.unlock() }
        return albums[id]
    }

    private func setMemoryAlbum(_ album: AlbumWithSongsID3, forId id: String) {
        lock.lock()
        albums[id] = album
        lock.unlock()
    }

    // MARK: - Disk layer

    private func fileURL(forId id: String) -> URL? {
        guard let directory else { return nil }
        // Album ids can contain characters that aren't safe as a bare filename (e.g. "/"),
        // so percent-encode them; fall back to the raw id if it's already filename-safe.
        let safeName = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return directory.appendingPathComponent(safeName).appendingPathExtension("json")
    }

    private func diskAlbum(forId id: String) -> AlbumWithSongsID3? {
        guard let url = fileURL(forId: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlbumWithSongsID3.self, from: data)
    }

    private func writeToDisk(_ album: AlbumWithSongsID3, id: String) {
        guard let url = fileURL(forId: id), let data = try? JSONEncoder().encode(album) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
