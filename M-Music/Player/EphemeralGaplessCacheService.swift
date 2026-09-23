import Foundation

/// The "Keep cached for: Never" backend for the upcoming-track gapless cache — modeled directly on
/// `GaplessCacheService` (same single-flight download dedup, same validation), but never persisted:
/// writes to the OS temp directory instead of `Application Support`, keeps no database, and holds
/// at most the current and next track's files at any moment, deleting anything else immediately.
///
/// Ported from Shelv's `ShelvCore/Services/StreamCacheService.swift`, which uses the same
/// temp-file-per-song approach for its own upcoming-track pre-cache.
///
/// Publishes into the same `GaplessCacheStatus.shared` that `GaplessCacheService` uses, so
/// `PlayerManager`'s read side (`entry(for:)`, `isGaplessCacheEntry`, the `$cachedEntries`
/// subscription) works unchanged regardless of which backend produced an entry — only the call
/// sites that *write* need to pick the active backend, via `PlayerManager.usesEphemeralGaplessCache`.
actor EphemeralGaplessCacheService {
    static let shared = EphemeralGaplessCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    /// Every temp file this instance has written this launch, so a completed-but-superseded entry
    /// can still be found and deleted even after `activeTasks` no longer references it — unlike
    /// `GaplessCacheService.cancel`, which only stops in-flight downloads.
    private var writtenFiles: [String: URL] = [:]

    private static let requestTimeout: TimeInterval = 240
    private static let filenamePrefix = "gapless-ephemeral-"

    private static func tempURL(songId: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)\(songId.pathSafeComponent)")
            .appendingPathExtension(ext.pathSafeFileExtension())
    }

    /// Fire-and-forget prefetch of the *next* track — mirrors `GaplessCacheService.enqueue`.
    func enqueue(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) {
        guard GaplessCacheSettings.isEnabled else { return }
        _ = downloadTask(song: song, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension)
    }

    /// Blocking cache-then-play for the *current* track — mirrors `GaplessCacheService.cacheAndWait`.
    func cacheAndWait(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) async -> URL? {
        guard GaplessCacheSettings.isEnabled else { return nil }
        let songId = song.id.raw
        await downloadTask(song: song, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension).value
        return await MainActor.run { GaplessCacheStatus.shared.entry(for: songId)?.url }
    }

    private func downloadTask(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) -> Task<Void, Never> {
        let songId = song.id.raw
        if let existing = activeTasks[songId] { return existing }
        Task { @MainActor in GaplessCacheStatus.shared.markActive(songId) }
        let task = Task {
            await self.download(song: song, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension)
            self.activeTasks.removeValue(forKey: songId)
        }
        activeTasks[songId] = task
        return task
    }

    /// Cancels an in-flight download (if any) and deletes `songId`'s temp file (if any) — unlike
    /// `GaplessCacheService.cancel`, which leaves an already-completed download alone, ephemeral
    /// mode wants a superseded entry gone outright.
    func cancel(songId: String) {
        if let task = activeTasks[songId] {
            task.cancel()
            activeTasks.removeValue(forKey: songId)
        }
        if let fileURL = writtenFiles.removeValue(forKey: songId) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        Task { @MainActor in GaplessCacheStatus.shared.remove(songId) }
    }

    /// Nothing to extend the retention of in ephemeral mode.
    func touch(songId: String) {}

    func removeIfPresent(songId: String) async {
        cancel(songId: songId)
    }

    /// Deletes every written file except `keepIds` — called once a new current track is resolved,
    /// so ephemeral mode never holds more than "current + next" on disk at once.
    func prune(keeping keepIds: Set<String>) {
        for songId in writtenFiles.keys where !keepIds.contains(songId) {
            cancel(songId: songId)
        }
    }

    private func download(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) async {
        let songId = song.id.raw
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeout
            let (tmpURL, response) = try await URLSession.shared.download(for: request)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: tmpURL)
                return
            }
            let http = response as? HTTPURLResponse
            let byteSize = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let validation = try await DownloadPayloadValidator.validate(
                fileURL: tmpURL, byteSize: byteSize, statusCode: http?.statusCode, mimeType: http?.mimeType,
                fallbackFileExtension: fallbackExtension
            )
            let ext = (validation.fileExtension ?? fallbackExtension).pathSafeFileExtension()
            let destination = Self.tempURL(songId: songId, ext: ext)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmpURL, to: destination)
            writtenFiles[songId] = destination

            let entry = GaplessCacheStatus.Entry(url: destination, format: format, bitrate: bitrate)
            await MainActor.run { GaplessCacheStatus.shared.markCached(songId, entry: entry) }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { GaplessCacheStatus.shared.remove(songId) }
        }
    }

    /// Deletes every temp file this service has written this launch and cancels anything in flight
    /// — called when the user switches "Keep cached for" away from "Never", so a leftover ephemeral
    /// file doesn't linger once persistent caching takes back over.
    func clearAll() async {
        for songId in Array(activeTasks.keys) { cancel(songId: songId) }
        for songId in Array(writtenFiles.keys) { cancel(songId: songId) }
    }

    /// Sweeps `gapless-ephemeral-*` files left in the temp directory from a previous launch that
    /// was killed before its own cleanup ran — mirrors Shelv's `StreamCacheService.cleanupOldFiles()`.
    /// Safe to call regardless of the current "Keep cached for" setting.
    func cleanupOrphanedFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix(Self.filenamePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
