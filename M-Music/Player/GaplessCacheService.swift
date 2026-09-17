import Foundation

/// Publishes which songs are currently caching/cached, and their cached file's format/bitrate —
/// `@MainActor` so `PlayerManager.streamURL(for:)` (itself `@MainActor`) can look up a cached
/// entry synchronously. `GaplessCacheService` itself is an actor and can only be reached with
/// `await`, which a synchronous URL-builder can't afford. Kept separate from `StreamCacheStatus`
/// even though the shape is similar — this one is a persistent, user-sized cache with a different
/// lifecycle, not `StreamCacheService`'s ephemeral current+next window.
@MainActor
final class GaplessCacheStatus: ObservableObject {
    static let shared = GaplessCacheStatus()

    struct Entry: Equatable {
        let url: URL
        let format: String
        let bitrate: Int
    }

    @Published private(set) var activeSongIds: Set<String> = []
    @Published private(set) var cachedEntries: [String: Entry] = [:]

    private init() {}

    func markActive(_ songId: String) {
        activeSongIds.insert(songId)
    }

    func markCached(_ songId: String, entry: Entry) {
        activeSongIds.remove(songId)
        cachedEntries[songId] = entry
    }

    func remove(_ songId: String) {
        activeSongIds.remove(songId)
        cachedEntries.removeValue(forKey: songId)
    }

    func removeAll() {
        activeSongIds.removeAll()
        cachedEntries.removeAll()
    }

    func entry(for songId: String) -> Entry? {
        cachedEntries[songId]
    }
}

/// Downloads the *upcoming* track to a real file ahead of the boundary, for any track — raw or
/// transcoded — so `PlayerManager` can gapless-preload it once it lands, kept as a persistent,
/// size/age-bounded cache the user configures (`GaplessCacheSettings`) rather than
/// `StreamCacheService`'s ephemeral current+next window. Opt-in: every method below is a no-op
/// while `GaplessCacheSettings.isEnabled` is `false`.
///
/// Modeled on `StreamCacheService`'s download-with-retry pattern (a plain `URLSession`, not a
/// background session — see the plan's design note on why that's the right call here) rather than
/// `DownloadService`'s heavier background-session machinery.
actor GaplessCacheService {
    static let shared = GaplessCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    /// A generous timeout — unlike an ordinary file download, a transcoded stream can only be
    /// downloaded about as fast as it's encoded, so this needs to cover roughly "as long as the
    /// current track plays," not just a quick file fetch.
    private static let requestTimeout: TimeInterval = 240

    private static func destinationDirectory() -> URL {
        GaplessCacheDatabase.rootDirectory()
    }

    private static func destinationURL(songId: String, ext: String) -> URL {
        destinationDirectory().appendingPathComponent("\(songId.pathSafeComponent).\(ext.pathSafeFileExtension())")
    }

    /// `fallbackExtension` is used only if the downloaded payload can't be identified by content
    /// sniffing or MIME type (rare) — the caller's best guess at the real file extension (the
    /// track's own `suffix` for a raw file, or the transcode codec for a transcoded one). `song`
    /// is only ever used for its display metadata (title/artist/album), for
    /// `PlaybackSettingsView`'s cached-songs list — playback resolution is always by `song.id.raw`.
    func enqueue(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) {
        guard GaplessCacheSettings.isEnabled else { return }
        _ = downloadTask(song: song, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension)
    }

    /// Awaits `song` being cached — kicking off the download if nothing's already in flight for
    /// it, or just waiting on the existing one (e.g. one `prepareNextItemViaGaplessCache` already
    /// started) rather than starting a duplicate — and returns the resulting local file URL, or
    /// `nil` if the download failed or was cancelled meanwhile.
    ///
    /// Used by `PlayerManager.cacheThenPlay(...)`: with `GaplessCacheSettings.isEnabled`, the app
    /// never hands `PlayerEngine` a live network URL, so a track with nothing cached yet has to be
    /// downloaded to a real file *before* playback can start at all.
    func cacheAndWait(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) async -> URL? {
        guard GaplessCacheSettings.isEnabled else { return nil }
        let songId = song.id.raw
        await downloadTask(song: song, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension).value
        return await MainActor.run { GaplessCacheStatus.shared.entry(for: songId)?.url }
    }

    /// The single-flight download task for `song.id.raw` — reuses whatever's already running for
    /// that song (started by `enqueue` or a previous `cacheAndWait`) instead of starting a second,
    /// redundant download of the same file.
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

    /// A no-op unless `songId` is still actively downloading — safe to call on a song that has
    /// already finished caching (or was never enqueued) without evicting its valid entry.
    func cancel(songId: String) {
        guard let task = activeTasks[songId] else { return }
        task.cancel()
        activeTasks.removeValue(forKey: songId)
        Task { @MainActor in GaplessCacheStatus.shared.remove(songId) }
    }

    /// Marks a cached track as just played, so it outlives the retention window while it's still
    /// in active use instead of aging out from under it.
    func touch(songId: String) {
        Task { await GaplessCacheDatabase.shared.touch(songId: songId) }
    }

    /// Removes any in-flight or already-completed gapless-cache copy of `songId` — used once a
    /// real download for that song lands, making the gapless-cache copy redundant per the
    /// "downloaded songs always win" rule in `PlayerManager.streamURL(for:)`/
    /// `prepareNextItemViaGaplessCache`. A safe no-op if there's nothing cached for this song.
    func removeIfPresent(songId: String) async {
        cancel(songId: songId)
        guard let record = await GaplessCacheDatabase.shared.record(songId: songId) else { return }
        await GaplessCacheDatabase.shared.delete(songId: songId)
        try? FileManager.default.removeItem(at: record.fileURL)
        await MainActor.run { GaplessCacheStatus.shared.remove(songId) }
    }

    /// Loads previously-cached rows from disk into `GaplessCacheStatus` — called once. `download`
    /// also calls this itself as a defensive fallback, but the real caller is `PlayerManager.init`,
    /// eagerly at launch: `GaplessCacheStatus.entry(for:)` is a plain synchronous dictionary read
    /// with no way to lazily trigger this on its own, so without an eager call here, a track
    /// that's already cached from an earlier session would wrongly stream live instead of loading
    /// from disk if tapped before any *other* download happened to run first this session.
    ///
    /// Also runs eviction once here, not only as a side effect of a new download landing (see
    /// `download(...)` below) — a session that never caches anything new (replaying an
    /// already-fully-cached set of tracks, say) would otherwise never enforce the user's own
    /// size-limit/retention settings at all, since nothing else ever triggers that check.
    private var didLoadExisting = false
    func preload() async {
        guard !didLoadExisting else { return }
        didLoadExisting = true
        let records = await GaplessCacheDatabase.shared.allRecords()
        for record in records where FileManager.default.fileExists(atPath: record.fileURL.path) {
            let entry = GaplessCacheStatus.Entry(url: record.fileURL, format: record.format, bitrate: record.bitrate)
            await MainActor.run { GaplessCacheStatus.shared.markCached(record.songId, entry: entry) }
        }
        await runEviction()
    }

    private func download(song: Child, url: URL, format: String, bitrate: Int, fallbackExtension: String) async {
        let songId = song.id.raw
        await preload()
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
            try? FileManager.default.createDirectory(at: Self.destinationDirectory(), withIntermediateDirectories: true)
            let destination = Self.destinationURL(songId: songId, ext: ext)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmpURL, to: destination)

            let now = Date()
            let record = GaplessCacheRecord(
                songId: songId, format: format, bitrate: bitrate, filePath: destination.path,
                fileExtension: ext, byteSize: byteSize, cachedAt: now, lastPlayedAt: now,
                title: song.title, artist: song.artist, album: song.album, albumId: song.albumId?.raw
            )
            await GaplessCacheDatabase.shared.upsert(record)
            await runEviction()

            let entry = GaplessCacheStatus.Entry(url: destination, format: format, bitrate: bitrate)
            await MainActor.run { GaplessCacheStatus.shared.markCached(songId, entry: entry) }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { GaplessCacheStatus.shared.remove(songId) }
        }
    }

    /// Deletes every cached track and cancels anything in flight — "Clear cache" in
    /// `PlaybackSettingsView`.
    func clearAll() async {
        for songId in Array(activeTasks.keys) {
            cancel(songId: songId)
        }
        let records = await GaplessCacheDatabase.shared.deleteAll()
        for record in records {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        await MainActor.run { GaplessCacheStatus.shared.removeAll() }
    }

    private func runEviction() async {
        let overBudget = await GaplessCacheDatabase.shared.evictOverBudget(maxBytes: GaplessCacheSettings.sizeLimit.byteCount)
        let cutoff = Calendar.current.date(byAdding: .day, value: -GaplessCacheSettings.retention.rawValue, to: Date()) ?? .distantPast
        let stale = await GaplessCacheDatabase.shared.evictOlderThan(cutoff)
        for record in overBudget + stale {
            try? FileManager.default.removeItem(at: record.fileURL)
            await MainActor.run { GaplessCacheStatus.shared.remove(record.songId) }
        }
    }
}
