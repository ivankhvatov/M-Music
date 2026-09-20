import Foundation
import UIKit

/// Metadata for one queued/in-flight download, JSON-encoded into the `URLSessionDownloadTask`'s
/// `taskDescription` — that's what lets a download started before the app was killed still be
/// turned into a complete `DownloadRecord` once `AppDelegate` relaunches the background session
/// and this actor's `setup()` restores it, with no in-memory state to have survived the relaunch.
private struct DownloadJob: Codable, Sendable {
    let songId: String
    let title: String
    let artist: String?
    let album: String?
    let albumId: String?
    let artistId: String?
    let coverArt: String?
    let track: Int?
    let discNumber: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let bitRate: Int?
    let replayGainTrackGain: Double?
    let replayGainAlbumGain: Double?
    let format: String
    let fallbackExtension: String

    init(song: Child, requestedBitRate: Int?, format: String, fallbackExtension: String) {
        songId = song.id.raw
        title = song.title
        artist = song.artist
        album = song.album
        albumId = song.albumId?.raw
        artistId = song.artistId?.raw
        coverArt = song.coverArt
        track = song.track
        discNumber = song.discNumber
        duration = song.duration
        year = song.year
        genre = song.genre
        bitRate = requestedBitRate ?? song.bitRate
        replayGainTrackGain = song.replayGain?.trackGain
        replayGainAlbumGain = song.replayGain?.albumGain
        self.format = format
        self.fallbackExtension = fallbackExtension
    }
}

/// Downloads songs (original quality or transcoded, per `DownloadTranscodingSettings`) on a
/// background `URLSession` so they survive the app being backgrounded or suspended, validates
/// each payload, and persists the result via `DownloadDatabase`/`LocalDownloadIndex`.
///
/// A trimmed rebuild of Shelv's `ShelvCore/Services/DownloadService.swift` job-queue core: no
/// album/artist/playlist catalog observation, bulk plans, or keep-library-offline — M-Music
/// doesn't have the surrounding library-sync machinery those depend on, and downloads here are
/// always an explicit, one-off "download this song/album" request.
actor DownloadService {
    static let shared = DownloadService()

    struct Update: Sendable {
        let songId: String
        let state: DownloadState
    }

    private let client = SubsonicClient.shared
    private let limiter = ConcurrencyLimiter(maxConcurrent: 3)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
    }()
    private lazy var coordinator = Coordinator()
    private static let sessionIdentifier = "com.m-music.downloads"

    private var jobByTaskIdentifier: [Int: DownloadJob] = [:]
    private var taskIdentifierBySongId: [String: Int] = [:]
    private var progressCoalescer: DownloadProgressCoalescer?
    private var continuation: AsyncStream<Update>.Continuation?
    private var backgroundCompletionHandler: (() -> Void)?
    private var didSetup = false

    private init() {}

    func updates() -> AsyncStream<Update> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Wires up the background session's delegate queue and restores any in-flight tasks from a
    /// previous launch. Called lazily on first use rather than from `init()`, so creating the
    /// (lazy) `session` — which touches `URLSessionConfiguration.background` — doesn't happen
    /// until a download is actually needed.
    private func ensureSetup() {
        guard !didSetup else { return }
        didSetup = true
        progressCoalescer = DownloadProgressCoalescer(
            schedule: { work in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work) },
            emit: { [weak self] samples in
                guard let self else { return }
                Task { await self.handleProgress(samples) }
            }
        )
        Task {
            let tasks = await session.allTasks
            for case let task as URLSessionDownloadTask in tasks {
                guard let description = task.taskDescription,
                      let data = description.data(using: .utf8),
                      let job = try? JSONDecoder().decode(DownloadJob.self, from: data)
                else { continue }
                jobByTaskIdentifier[task.taskIdentifier] = job
                taskIdentifierBySongId[job.songId] = task.taskIdentifier
                continuation?.yield(Update(songId: job.songId, state: .downloading(progress: 0)))
            }
        }
    }

    // MARK: - Enqueueing

    func enqueue(song: Child) {
        ensureSetup()
        continuation?.yield(Update(songId: song.id.raw, state: .queued))
        Task { await startJob(for: song) }
    }

    func enqueueAlbum(songs: [Child]) {
        ensureSetup()
        for song in songs {
            continuation?.yield(Update(songId: song.id.raw, state: .queued))
            Task { await startJob(for: song) }
        }
    }

    private func startJob(for song: Child) async {
        guard await limiter.acquire() else { return }
        guard taskIdentifierBySongId[song.id.raw] == nil else {
            await limiter.release()
            return
        }
        do {
            let url: URL
            let requestedBitRate: Int?
            let format: String
            let fallbackExtension: String
            if DownloadTranscodingSettings.isEnabled {
                let transcodeFormat = DownloadTranscodingSettings.format
                let bitrate = DownloadTranscodingSettings.bitrate
                url = try client.streamURL(forId: song.id.raw, maxBitRate: bitrate.rawValue, format: transcodeFormat.rawValue)
                requestedBitRate = bitrate.rawValue
                format = transcodeFormat.rawValue
                fallbackExtension = transcodeFormat.rawValue
            } else {
                url = try client.downloadURL(forId: song.id.raw)
                requestedBitRate = song.bitRate
                format = "raw"
                fallbackExtension = song.suffix ?? "mp3"
            }
            let job = DownloadJob(song: song, requestedBitRate: requestedBitRate, format: format, fallbackExtension: fallbackExtension)
            guard let data = try? JSONEncoder().encode(job), let description = String(data: data, encoding: .utf8) else {
                await limiter.release()
                continuation?.yield(Update(songId: song.id.raw, state: .failed(message: "Could not prepare download")))
                return
            }
            let task = session.downloadTask(with: url)
            task.taskDescription = description
            jobByTaskIdentifier[task.taskIdentifier] = job
            taskIdentifierBySongId[song.id.raw] = task.taskIdentifier
            task.resume()
        } catch {
            await limiter.release()
            continuation?.yield(Update(songId: song.id.raw, state: .failed(message: error.localizedDescription)))
        }
    }

    // MARK: - Cancel / Delete

    func cancel(songId: String) async {
        guard let taskIdentifier = taskIdentifierBySongId[songId] else { return }
        let tasks = await session.allTasks
        tasks.first { $0.taskIdentifier == taskIdentifier }?.cancel()
        clearJob(taskIdentifier: taskIdentifier, songId: songId)
        continuation?.yield(Update(songId: songId, state: .none))
    }

    func delete(songId: String) async {
        await cancel(songId: songId)
        if let record = await DownloadDatabase.shared.record(songId: songId) {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        await DownloadDatabase.shared.delete(songId: songId)
        LocalDownloadIndex.shared.setEntry(songId: songId, entry: nil)
        continuation?.yield(Update(songId: songId, state: .none))
    }

    func deleteAlbum(albumId: String) async {
        let records = await DownloadDatabase.shared.records(albumId: albumId)
        for record in records {
            await delete(songId: record.songId)
        }
    }

    func deleteAll() async {
        for songId in Array(taskIdentifierBySongId.keys) {
            await cancel(songId: songId)
        }
        let records = await DownloadDatabase.shared.allRecords()
        for record in records {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        await DownloadDatabase.shared.delete(songIds: records.map(\.songId))
        LocalDownloadIndex.shared.replaceAll([:])
    }

    private func clearJob(taskIdentifier: Int, songId: String) {
        jobByTaskIdentifier.removeValue(forKey: taskIdentifier)
        taskIdentifierBySongId.removeValue(forKey: songId)
        Task { await limiter.release() }
    }

    // MARK: - Background session plumbing

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, forSession identifier: String) {
        guard identifier == Self.sessionIdentifier else {
            handler()
            return
        }
        ensureSetup()
        backgroundCompletionHandler = handler
    }

    fileprivate func handleProgress(_ samples: [DownloadProgressSample]) {
        for sample in samples {
            guard let job = jobByTaskIdentifier[sample.taskIdentifier], sample.total > 0 else { continue }
            let progress = min(1, max(0, Double(sample.written) / Double(sample.total)))
            continuation?.yield(Update(songId: job.songId, state: .downloading(progress: progress)))
        }
    }

    fileprivate func handleDownloadFinished(
        taskIdentifier: Int, fileURL: URL, statusCode: Int?, mimeType: String?
    ) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let job = jobByTaskIdentifier[taskIdentifier] else { return }
        defer { clearJob(taskIdentifier: taskIdentifier, songId: job.songId) }

        do {
            let downloadedByteSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let validation = try await DownloadPayloadValidator.validate(
                fileURL: fileURL, byteSize: downloadedByteSize, statusCode: statusCode, mimeType: mimeType,
                fallbackFileExtension: job.fallbackExtension
            )
            var ext = (validation.fileExtension ?? job.fallbackExtension).pathSafeFileExtension()
            var destination = DownloadDatabase.rootDirectory().appendingPathComponent("\(job.songId.pathSafeComponent).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)

            var byteSize = downloadedByteSize
            var contentType = validation.contentType
            if let converted = await convertIfNeeded(originalURL: destination, ext: ext, songId: job.songId) {
                destination = converted.url
                ext = converted.ext
                byteSize = converted.byteSize
                contentType = converted.contentType
            }

            let record = DownloadRecord(
                songId: job.songId, title: job.title, artist: job.artist, album: job.album, albumId: job.albumId,
                coverArt: job.coverArt, track: job.track, discNumber: job.discNumber, duration: job.duration,
                year: job.year, genre: job.genre, filePath: destination.path, fileExtension: ext,
                contentType: contentType, bitRate: job.bitRate, byteSize: byteSize,
                replayGainTrackGain: job.replayGainTrackGain, replayGainAlbumGain: job.replayGainAlbumGain,
                addedAt: Date(), format: job.format
            )
            await DownloadDatabase.shared.upsert(record)
            LocalDownloadIndex.shared.setEntry(
                songId: job.songId, entry: .init(path: destination.path, format: job.format, bitRate: job.bitRate)
            )
            Task {
                await self.precacheArtwork(
                    coverArt: job.coverArt, albumId: job.albumId, artistId: job.artistId, songId: job.songId
                )
            }
            continuation?.yield(Update(songId: job.songId, state: .completed))
        } catch {
            continuation?.yield(Update(songId: job.songId, state: .failed(message: error.localizedDescription)))
        }
    }

    /// Best-effort: pre-warms durable artwork for a just-finished download, at both the sizes
    /// `SongRow` and `AlbumRow` actually request, plus the song's artist picture (full size only —
    /// `ArtistsListView`/`ArtistAlbumsView` both request it unscaled), so it's all available
    /// offline without the eviction risk of the regular Caches-backed image cache. Never affects
    /// download completion — every failure here just means that artwork stays lazily-fetched like
    /// before this feature existed. `precacheDurably` itself already no-ops if an entry is already
    /// cached, so this is safe to call on every download without checking "is it cached?" first.
    private func precacheArtwork(coverArt: String?, albumId: String?, artistId: String?, songId: String) async {
        let songArtId = coverArt ?? albumId ?? songId
        let scale = await MainActor.run { UIScreen.main.scale }
        // Mirrors SongsListView.rowArtworkSize/PlaylistView.rowArtworkSize (44pt) and
        // AlbumsListView.rowArtworkSize (64pt) — kept in sync by hand since those are private
        // per-view constants; a mismatch only means a missed cache hit, not a correctness bug.
        let songThumbSize = Int(44 * scale)
        let albumThumbSize = Int(64 * scale)

        if let songFullURL = try? client.coverArtURL(forId: songArtId) {
            await ImageCache.shared.precacheDurably(songFullURL)
        }
        if let songThumbURL = try? client.coverArtURL(forId: songArtId, size: songThumbSize) {
            await ImageCache.shared.precacheDurably(songThumbURL)
        }

        if let albumId {
            let albumArtId = await resolveAlbumCoverArtId(albumId: albumId) ?? albumId
            if let albumFullURL = try? client.coverArtURL(forId: albumArtId) {
                await ImageCache.shared.precacheDurably(albumFullURL)
            }
            if let albumThumbURL = try? client.coverArtURL(forId: albumArtId, size: albumThumbSize) {
                await ImageCache.shared.precacheDurably(albumThumbURL)
            }
        }

        if let artistId {
            let artistArtId = await resolveArtistCoverArtId(artistId: artistId) ?? artistId
            if let artistFullURL = try? client.coverArtURL(forId: artistArtId) {
                await ImageCache.shared.precacheDurably(artistFullURL)
            }
        }
    }

    /// The album's own authoritative `coverArt` id — checked against the offline library-metadata
    /// cache first (already populated in the common case: opening an album's screen, which is how
    /// a user gets to the "Download Album" button in the first place, already caches this),
    /// falling back to a live lookup only if it's genuinely never been fetched this session/install.
    private func resolveAlbumCoverArtId(albumId: String) async -> String? {
        if let cached = await LibraryCacheDatabase.shared.cachedAlbumSongs(albumId: albumId) {
            return cached.coverArt
        }
        return try? await client.getAlbum(id: albumId).coverArt
    }

    /// The artist's own authoritative `coverArt` id — same reasoning as `resolveAlbumCoverArtId`:
    /// checked against the offline library-metadata cache first (`ArtistsListView`/
    /// `LibrarySyncService` already populate this in the common case), falling back to a live
    /// lookup only if this artist's never been fetched this session/install.
    private func resolveArtistCoverArtId(artistId: String) async -> String? {
        if let cachedArtists = await LibraryCacheDatabase.shared.cachedAllArtists(),
           let match = cachedArtists.first(where: { $0.id.raw == artistId }) {
            return match.coverArt
        }
        return try? await client.getArtist(id: artistId).coverArt
    }

    private struct ConversionResult {
        let url: URL
        let ext: String
        let byteSize: Int64
        let contentType: String?
    }

    private static let losslessConversionExtensions: Set<String> = ["flac", "wav", "aiff"]

    /// Runs the on-device post-download conversion configured in `DownloadConversionSettings`, if
    /// any applies to `ext`. On success, `originalURL` has already been deleted and the returned
    /// `ConversionResult` points at the new file the caller should use in its place. On failure —
    /// a corrupt/unsupported source, a multichannel Opus file, disk pressure, ... — this asserts
    /// (visible in debug builds, a no-op in release) and returns `nil`; the caller keeps using
    /// `originalURL` untouched. A user always ends up with a playable file either way — a
    /// conversion bug should never turn a successful download into a failed one.
    private func convertIfNeeded(originalURL: URL, ext: String, songId: String) async -> ConversionResult? {
        do {
            if DownloadConversionSettings.convertLosslessToALAC, Self.losslessConversionExtensions.contains(ext) {
                let convertedURL = try await LosslessToALACConverter.convert(sourceURL: originalURL)
                return try finalizeConversion(
                    convertedURL: convertedURL, originalURL: originalURL, songId: songId, ext: "m4a", contentType: "audio/mp4"
                )
            }
            if DownloadConversionSettings.convertOpusToCAF, ext == "opus" {
                let convertedURL = try await OpusToCAFRemuxer.remux(sourceURL: originalURL)
                return try finalizeConversion(
                    convertedURL: convertedURL, originalURL: originalURL, songId: songId, ext: "caf", contentType: nil
                )
            }
            return nil
        } catch {
            assertionFailure("Download conversion failed for song \(songId) (.\(ext)), keeping original file: \(error)")
            return nil
        }
    }

    /// Moves a converter's temp-directory output into the real downloads directory (same naming
    /// scheme, new extension), only then deletes the now-superseded original, and measures the
    /// final byte size. `originalURL` is never touched until the converted file is confirmed
    /// moved into place, so a thrown error here still leaves a fully intact, playable original —
    /// `convertIfNeeded`'s catch treats it identically to any other conversion failure.
    private func finalizeConversion(
        convertedURL: URL, originalURL: URL, songId: String, ext: String, contentType: String?
    ) throws -> ConversionResult {
        defer { try? FileManager.default.removeItem(at: convertedURL) }
        let destination = DownloadDatabase.rootDirectory().appendingPathComponent("\(songId.pathSafeComponent).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: convertedURL, to: destination)
        try? FileManager.default.removeItem(at: originalURL)
        let byteSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ConversionResult(url: destination, ext: ext, byteSize: byteSize, contentType: contentType)
    }

    fileprivate func handleTaskCompletion(taskIdentifier: Int, error: Error?) {
        guard let job = jobByTaskIdentifier[taskIdentifier] else { return }
        defer { clearJob(taskIdentifier: taskIdentifier, songId: job.songId) }
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else {
            continuation?.yield(Update(songId: job.songId, state: .none))
            return
        }
        continuation?.yield(Update(songId: job.songId, state: .failed(message: error.localizedDescription)))
    }

    fileprivate func handleBackgroundSessionFinishedEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    /// Forwards `URLSessionDownloadDelegate` callbacks into the actor. A delegate's callbacks run
    /// off the main actor on a background queue, not inside `DownloadService`'s own isolation, so
    /// this only ever does synchronous, delegate-queue-safe work (moving the downloaded file
    /// somewhere stable before it's deleted) before hopping over with `Task { await ... }`.
    private final class Coordinator: NSObject, URLSessionDownloadDelegate {
        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            let holding = FileManager.default.temporaryDirectory
                .appendingPathComponent("mmusic_download_\(downloadTask.taskIdentifier)_\(UUID().uuidString).tmp")
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
            let mimeType = downloadTask.response?.mimeType
            let taskIdentifier = downloadTask.taskIdentifier
            do {
                try FileManager.default.moveItem(at: location, to: holding)
            } catch {
                Task { await DownloadService.shared.handleTaskCompletion(taskIdentifier: taskIdentifier, error: error) }
                return
            }
            Task {
                await DownloadService.shared.handleDownloadFinished(
                    taskIdentifier: taskIdentifier, fileURL: holding, statusCode: statusCode, mimeType: mimeType
                )
            }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            let sample = DownloadProgressSample(
                taskIdentifier: downloadTask.taskIdentifier, written: totalBytesWritten, total: totalBytesExpectedToWrite
            )
            Task { await DownloadService.shared.recordProgress(sample) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let taskIdentifier = task.taskIdentifier
            Task { await DownloadService.shared.handleTaskCompletion(taskIdentifier: taskIdentifier, error: error) }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { await DownloadService.shared.handleBackgroundSessionFinishedEvents() }
        }
    }

    fileprivate func recordProgress(_ sample: DownloadProgressSample) {
        ensureSetup()
        progressCoalescer?.record(sample)
    }
}
