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

    /// Just enough of a `DownloadRecord` for `PlayerManager` to both resolve a download's file
    /// and decide whether it's still valid to use — `format`/`bitRate` mirror `DownloadRecord`'s
    /// own fields (see its doc comments) rather than duplicating their meaning here.
    struct Entry {
        let path: String
        let format: String?
        let bitRate: Int?
    }

    private var entryBySongId: [String: Entry] = [:]

    private init() {}

    func replaceAll(_ entries: [String: Entry]) {
        lock.lock()
        entryBySongId = entries
        lock.unlock()
    }

    func setEntry(songId: String, entry: Entry?) {
        lock.lock()
        if let entry { entryBySongId[songId] = entry } else { entryBySongId.removeValue(forKey: songId) }
        lock.unlock()
    }

    func entry(songId: String) -> Entry? {
        lock.lock()
        let entry = entryBySongId[songId]
        lock.unlock()
        return entry
    }

    /// The file's URL, regardless of its format's current validity for playback — callers that
    /// care about that (`PlayerManager`) should go through `entry(songId:)` and their own format
    /// check instead; this is for callers that just want "is a download for this song on disk."
    func url(songId: String) -> URL? {
        guard let path = entry(songId: songId)?.path else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func contains(songId: String) -> Bool {
        entry(songId: songId) != nil
    }
}
