import Foundation

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
            let byteSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let validation = try await DownloadPayloadValidator.validate(
                fileURL: fileURL, byteSize: byteSize, statusCode: statusCode, mimeType: mimeType,
                fallbackFileExtension: job.fallbackExtension
            )
            let ext = (validation.fileExtension ?? job.fallbackExtension).pathSafeFileExtension()
            let destination = DownloadDatabase.rootDirectory().appendingPathComponent("\(job.songId.pathSafeComponent).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)

            let record = DownloadRecord(
                songId: job.songId, title: job.title, artist: job.artist, album: job.album, albumId: job.albumId,
                coverArt: job.coverArt, track: job.track, discNumber: job.discNumber, duration: job.duration,
                year: job.year, genre: job.genre, filePath: destination.path, fileExtension: ext,
                contentType: validation.contentType, bitRate: job.bitRate, byteSize: byteSize,
                replayGainTrackGain: job.replayGainTrackGain, replayGainAlbumGain: job.replayGainAlbumGain,
                addedAt: Date(), format: job.format
            )
            await DownloadDatabase.shared.upsert(record)
            LocalDownloadIndex.shared.setEntry(
                songId: job.songId, entry: .init(path: destination.path, format: job.format, bitRate: job.bitRate)
            )
            continuation?.yield(Update(songId: job.songId, state: .completed))
        } catch {
            continuation?.yield(Update(songId: job.songId, state: .failed(message: error.localizedDescription)))
        }
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
