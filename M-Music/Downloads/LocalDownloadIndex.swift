import Foundation

/// A synchronous, thread-safe lookup for local downloads — kept in memory (rather than going
/// through `DownloadDatabase`'s actor) since `PlayerManager.streamURL(for:)` and SwiftUI view
/// bodies both need an instant, non-`await`-able answer.
///
/// Ported from Shelv's `ShelvCore/Services/LocalDownloadIndex.swift` (drops the `serverId`
/// component of the key — M-Music is single-server).
final class LocalDownloadIndex {
    static let shared = LocalDownloadIndex()
    private let lock = NSLock()
    private var pathBySongId: [String: String] = [:]

    private init() {}

    func replaceAll(_ paths: [String: String]) {
        lock.lock()
        pathBySongId = paths
        lock.unlock()
    }

    func setPath(songId: String, path: String?) {
        lock.lock()
        if let path { pathBySongId[songId] = path } else { pathBySongId.removeValue(forKey: songId) }
        lock.unlock()
    }

    func url(songId: String) -> URL? {
        lock.lock()
        let path = pathBySongId[songId]
        lock.unlock()
        guard let path else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func contains(songId: String) -> Bool {
        lock.lock()
        let exists = pathBySongId[songId] != nil
        lock.unlock()
        return exists
    }
}
