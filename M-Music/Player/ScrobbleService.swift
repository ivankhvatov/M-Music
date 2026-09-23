import Foundation

/// Sends scrobbles to the server, holding on to any that can't be delivered right now (offline,
/// server down) and re-sending them — strictly in the order they were made — once it's reachable
/// again. The pending list is persisted as JSON so it survives the app being killed.
actor ScrobbleService {
    static let shared = ScrobbleService()
    private init() {}

    private struct Entry: Codable {
        let id: UUID
        let songId: String
        let playedAt: Date
        /// Which server this was made against — an entry left over from a previous server is
        /// dropped rather than sent to one where its song id means something else (or nothing).
        let serverKey: String
    }

    private static let retryDelay: Duration = .seconds(30)

    private var entries: [Entry] = []
    private var didLoad = false
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("PendingScrobbles.json")
    }

    private static func currentServerKey() -> String? {
        SubsonicClient.shared.credentials.map { "\($0.baseURL.absoluteString)|\($0.username)" }
    }

    /// Records that `songId` was listened to starting at `playedAt`, then tries to send it (and
    /// anything still pending ahead of it). Always queued behind older pending scrobbles, never
    /// sent ahead of them.
    func submit(songId: String, playedAt: Date) async {
        guard ScrobbleSettings.isEnabled, let serverKey = Self.currentServerKey() else { return }
        loadIfNeeded()
        entries.append(Entry(id: UUID(), songId: songId, playedAt: playedAt, serverKey: serverKey))
        persist()
        await flush()
    }

    /// Sends pending scrobbles one at a time, oldest first. Stops at the first transient failure
    /// (keeping that entry and everything after it) and retries later; an entry the server
    /// definitively rejects is dropped so it can't block the ones behind it forever.
    func flush() async {
        guard !isFlushing else { return }
        guard ScrobbleSettings.isEnabled else { return }
        loadIfNeeded()
        guard !entries.isEmpty, let serverKey = Self.currentServerKey() else { return }
        guard NetworkMonitor.shared.hasNetwork else {
            scheduleRetry()
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        while let entry = entries.first {
            guard ScrobbleSettings.isEnabled else { return }
            if entry.serverKey != serverKey {
                entries.removeFirst()
                persist()
                continue
            }
            do {
                try await SubsonicClient.shared.scrobble(ids: [entry.songId], times: [entry.playedAt], submission: true)
                removeEntry(id: entry.id)
            } catch {
                if Self.isTransient(error) {
                    scheduleRetry()
                    return
                }
                removeEntry(id: entry.id)
            }
        }
    }

    /// Discards everything pending — turning "Track listening history" off means nothing more
    /// gets sent, including what was still waiting.
    func clearAll() {
        retryTask?.cancel()
        retryTask = nil
        entries = []
        didLoad = true
        persist()
    }

    private func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task {
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            await self.flush()
        }
    }

    /// Whether `error` means "couldn't reach / the server had a problem" (worth retrying the same
    /// scrobble later) rather than "the server understood and refused it" (retrying can't help).
    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let subsonicError = error as? SubsonicError else { return false }
        switch subsonicError {
        case .http(let status):
            return status >= 500 || status == 408 || status == 429
        case .invalidResponse, .notConfigured:
            return true
        case .invalidBaseURL, .decoding, .server:
            return false
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
