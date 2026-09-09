import Foundation

/// Publishes which songs are currently prefetching/prefetched, and their cached file's URL.
/// `@MainActor`, so `PlayerManager.streamURL(for:)` (itself `@MainActor`) can look up a cached
/// URL synchronously — `StreamCacheService` itself is an actor and can only be reached with
/// `await`, which a synchronous URL-builder can't afford.
@MainActor
final class StreamCacheStatus: ObservableObject {
    static let shared = StreamCacheStatus()

    @Published private(set) var activeSongIds: Set<String> = []
    @Published private(set) var cachedURLs: [String: URL] = [:]

    private init() {}

    func markActive(_ songId: String) {
        activeSongIds.insert(songId)
    }

    func markCached(_ songId: String, url: URL) {
        activeSongIds.remove(songId)
        cachedURLs[songId] = url
    }

    func remove(_ songId: String) {
        activeSongIds.remove(songId)
        cachedURLs.removeValue(forKey: songId)
    }

    func url(for songId: String) -> URL? {
        cachedURLs[songId]
    }
}

struct ActualStreamFormat: Equatable, Sendable {
    let codecLabel: String
    let bitrateKbps: Int?

    static func codecLabel(forMime mime: String?) -> String {
        guard let m = mime?.lowercased() else { return "?" }
        switch m {
        case "audio/mpeg", "audio/mp3": return "MP3"
        case "audio/aac", "audio/aacp": return "AAC"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "AAC"
        case "audio/ogg", "audio/opus", "application/ogg", "audio/x-opus+ogg": return "OPUS"
        case "audio/flac", "audio/x-flac": return "FLAC"
        case "audio/wav", "audio/x-wav": return "WAV"
        case "audio/webm": return "WEBM"
        default: return m.split(separator: "/").last.map { String($0).uppercased() } ?? "?"
        }
    }
}

/// Prefetches the *upcoming* track in the queue to a temp file, so that by the time
/// `PlayerEngine.preloadForGapless(url:)` needs a URL for it, it can often hand the queue player a
/// local file instead of a network one — a smoother handoff, and resilient to a momentary network
/// blip right at the track boundary. Downloaded songs (see `LocalDownloadIndex`) are checked
/// first by `PlayerManager` and never go through here.
///
/// Ported from Shelv's `ShelvCore/Services/StreamCacheService.swift` (drops the `serverId`
/// component of every key — M-Music is single-server).
actor StreamCacheService {
    static let shared = StreamCacheService()
    private init() {}

    private var activeTasks: [String: Task<Bool, Never>] = [:]
    private var cachedURLs: [String: URL] = [:]
    private static let requestTimeout: TimeInterval = 10

    private static func tempURL(for songId: String, ext: String = "") -> URL {
        let safeSongId = songId.pathSafeComponent
        let name = ext.isEmpty ? "mmusic_stream_\(safeSongId)" : "mmusic_stream_\(safeSongId).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func fileExtension(for codecLabel: String) -> String {
        switch codecLabel.uppercased() {
        case "MP3": return "mp3"
        case "OPUS": return "opus"
        case "AAC": return "m4a"
        case "FLAC": return "flac"
        case "OGG": return "ogg"
        case "WAV": return "wav"
        case "M4A": return "m4a"
        case "AIFF", "AIF": return "aiff"
        default: return "audio"
        }
    }

    private static func deliveredFormat(
        from response: HTTPURLResponse, requested: ActualStreamFormat
    ) -> (format: ActualStreamFormat, fileExtension: String) {
        guard let ext = TranscodingSettings.extensionFor(mimeType: response.mimeType) else {
            return (requested, fileExtension(for: requested.codecLabel))
        }
        let codec = ActualStreamFormat.codecLabel(forMime: response.mimeType)
        return (ActualStreamFormat(codecLabel: codec, bitrateKbps: requested.bitrateKbps), ext)
    }

    func localURL(for songId: String) -> URL? {
        cachedURLs[songId]
    }

    func isActive(songId: String) -> Bool {
        activeTasks[songId] != nil
    }

    func prefetch(songId: String, url: URL, codec: String, bitrate: Int) {
        guard NetworkMonitor.shared.hasNetwork else {
            StreamCacheLog.log(songId: songId, message: "Prefetch skipped – offline")
            return
        }
        guard cachedURLs[songId] == nil, activeTasks[songId] == nil else { return }
        let desc = bitrate > 0 ? "\(codec.uppercased()) · \(bitrate) kbps" : codec.uppercased()
        StreamCacheLog.log(songId: songId, message: "Prefetch started (\(desc))")
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate > 0 ? bitrate : nil)
        Task { @MainActor in StreamCacheStatus.shared.markActive(songId) }
        activeTasks[songId] = Task {
            await self.downloadWithRetry(songId: songId, url: url, format: format, maxAttempts: 3)
        }
    }

    func cancel(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        if let url = cachedURLs.removeValue(forKey: songId) {
            try? FileManager.default.removeItem(at: url)
        }
        Task { @MainActor in StreamCacheStatus.shared.remove(songId) }
    }

    func cancelAll() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        for url in cachedURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        cachedURLs.removeAll()
    }

    /// Evicts every cached track except `keepSongIds` — called once a track finishes, so the
    /// cache doesn't grow to hold every track that's ever played this session.
    func trim(keeping keepSongIds: Set<String>) {
        for songId in cachedURLs.keys where !keepSongIds.contains(songId) {
            cancel(songId: songId)
        }
    }

    private func downloadWithRetry(songId: String, url: URL, format: ActualStreamFormat, maxAttempts: Int) async -> Bool {
        let requestedDest = Self.tempURL(for: songId, ext: Self.fileExtension(for: format.codecLabel))
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return false }
            guard NetworkMonitor.shared.hasNetwork else {
                StreamCacheLog.log(songId: songId, message: "Cancelled – offline")
                break
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = Self.requestTimeout
                let (tmpURL, response) = try await URLSession.shared.download(for: request)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    return false
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    StreamCacheLog.log(songId: songId, message: "Attempt \(attempt)/\(maxAttempts) – bad status")
                    if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    continue
                }
                let delivered = Self.deliveredFormat(from: http, requested: format)
                let dest = Self.tempURL(for: songId, ext: delivered.fileExtension)
                try? FileManager.default.removeItem(at: dest)
                if dest != requestedDest {
                    try? FileManager.default.removeItem(at: requestedDest)
                }
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                cachedURLs[songId] = dest
                activeTasks.removeValue(forKey: songId)
                Task { @MainActor in StreamCacheStatus.shared.markCached(songId, url: dest) }
                StreamCacheLog.log(songId: songId, message: "Cached ✓")
                return true
            } catch let urlError as URLError where urlError.code == .timedOut {
                StreamCacheLog.log(songId: songId, message: "Timeout – no retry")
                break
            } catch {
                guard !Task.isCancelled else { return false }
                StreamCacheLog.log(songId: songId, message: "Attempt \(attempt)/\(maxAttempts) – error: \(error.localizedDescription)")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        activeTasks.removeValue(forKey: songId)
        Task { @MainActor in StreamCacheStatus.shared.remove(songId) }
        StreamCacheLog.log(songId: songId, message: "All attempts failed")
        return false
    }
}
