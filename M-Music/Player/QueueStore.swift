import Foundation

/// Persists the play queue as a file, off the main thread.
///
/// The queue used to be JSON-encoded as part of `PlayerManager`'s state and written to
/// `UserDefaults` — on the main thread, on every play/pause/skip and every few seconds of
/// playback. Tapping one song in a large library queues *every* song in the list, so that was
/// several megabytes of JSON encoded and rewritten (as one preferences plist) again and again, and
/// decoded synchronously at launch. Now only the queue itself lives here, is only written when it
/// actually changes (debounced, encoded and written on this actor), and is read back off the main
/// thread; the small per-tick state (current track, index, position) stays in `UserDefaults` as a
/// few hundred bytes.
actor QueueStore {
    static let shared = QueueStore()

    private let fileURL: URL
    private let debounce: Duration

    private var pending: [Child]?
    private var lastWritten: [Child]?
    private var writeTask: Task<Void, Never>?

    init(fileURL: URL = QueueStore.defaultFileURL, debounce: Duration = .seconds(1)) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PlayerQueue.json")
    }

    /// Records the latest queue; it's written a moment later, and not at all if it's the same as
    /// what's already on disk (`Array ==` short-circuits when both share a buffer).
    func save(queue: [Child]) {
        pending = queue
        guard writeTask == nil else { return }
        writeTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            self.writeTask = nil
            self.flush()
        }
    }

    /// Writes any pending queue right away.
    func flush() {
        guard let queue = pending else { return }
        pending = nil
        guard queue != lastWritten else { return }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: fileURL, options: .atomic)
            lastWritten = queue
        } catch {
            // Try again with the next change.
        }
    }

    func clear() {
        writeTask?.cancel()
        writeTask = nil
        pending = nil
        lastWritten = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The last persisted queue, decoded here (off the main thread).
    func load() -> [Child]? {
        guard let data = try? Data(contentsOf: fileURL),
              let queue = try? JSONDecoder().decode([Child].self, from: data)
        else { return nil }
        lastWritten = queue
        return queue
    }
}
