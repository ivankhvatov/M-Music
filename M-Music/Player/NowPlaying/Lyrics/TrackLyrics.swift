import Foundation

/// A song's lyrics as the lyrics panel shows them.
enum TrackLyrics: Equatable, Sendable {
    case synced(LyricsTimeline)
    case plain(String)
    case unavailable
}

/// A song's lyrics as the server gave them, before their timing is worked out — and so what's
/// saved with a download (see `DownloadedLyrics`).
enum LyricsSource: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable {
        /// Seconds from the start of the song, the server's offset already applied.
        let start: TimeInterval
        let text: String
    }

    case synced([Line])
    case plain(String)
    /// The server has none. Saved all the same, so a downloaded song needn't ask again.
    case none

    var lyrics: TrackLyrics {
        switch self {
        case .synced(let lines):
            LyricsTimeline(timed: lines.map { ($0.start, $0.text) }).map(TrackLyrics.synced) ?? .unavailable
        case .plain(let text):
            .plain(text)
        case .none:
            .unavailable
        }
    }
}

/// Fetches lyrics, parses them and works out their timing — all off the main thread — and keeps
/// what it found, so reopening the panel, or coming back to a song, is instant.
actor LyricsLoader {
    static let shared = LyricsLoader()

    private var cache: [String: TrackLyrics] = [:]
    private var inFlight: [String: Task<TrackLyrics, Never>] = [:]

    /// Already-fetched lyrics for a track, if any.
    func cached(for track: Child) -> TrackLyrics? {
        cache[track.id.raw]
    }

    /// Starts fetching a track's lyrics, if they aren't already there or on their way.
    func prefetch(_ track: Child) {
        guard cache[track.id.raw] == nil, inFlight[track.id.raw] == nil else { return }
        _ = lyricsTask(for: track)
    }

    /// The track's lyrics. Concurrent requests for one track share a single fetch.
    func lyrics(for track: Child) async -> TrackLyrics {
        await lyricsTask(for: track).value
    }

    private func lyricsTask(for track: Child) -> Task<TrackLyrics, Never> {
        let id = track.id.raw
        if let cached = cache[id] { return Task { cached } }
        if let running = inFlight[id] { return running }
        let task = Task { [self] in
            let result = await Self.fetch(track)
            finish(id: id, result: result)
            return result.source.lyrics
        }
        inFlight[id] = task
        return task
    }

    private func finish(id: String, result: (source: LyricsSource, isDefinitive: Bool)) {
        inFlight[id] = nil
        // A network failure isn't "no lyrics" — don't remember it, so the next open tries again.
        guard result.isDefinitive else { return }
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[id] = result.source.lyrics
    }

    /// A downloaded song's lyrics are read from the device — which is where they were saved, if
    /// the song was downloaded with lyrics on; every other song's come from the server.
    private static func fetch(_ track: Child) async -> (source: LyricsSource, isDefinitive: Bool) {
        if let saved = await DownloadedLyrics.shared.lyrics(songId: track.id.raw) { return (saved, true) }
        return await fetchFromServer(songId: track.id.raw, artist: track.artist, title: track.title)
    }

    static func fetchFromServer(songId: String, artist: String?, title: String) async -> (source: LyricsSource, isDefinitive: Bool) {
        let client = SubsonicClient.shared
        var failed = false

        do {
            let sets = try await client.getLyricsBySongId(id: songId)
            if let found = choose(from: sets) { return (found, true) }
        } catch {
            failed = true
        }

        // Servers without `getLyricsBySongId` (or a song it has nothing for) may still answer the
        // older artist/title lookup, which gives plain text — occasionally LRC text.
        do {
            let legacy = try await client.getLyrics(artist: artist, title: title)
            if let text = legacy.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return (LRC.parse(text) ?? .plain(text), true)
            }
            failed = false
        } catch {
            failed = true
        }
        return (.none, !failed)
    }

    /// Prefers a synced set that has any text, then a plain one.
    private static func choose(from sets: [StructuredLyrics]) -> LyricsSource? {
        let hasText: (StructuredLyrics) -> Bool = { set in
            set.line.contains { !($0.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if let synced = sets.first(where: { $0.synced && hasText($0) }) {
            let offset = TimeInterval(synced.offset ?? 0) / 1000
            let lines = synced.line.compactMap { line -> LyricsSource.Line? in
                guard let start = line.start else { return nil }
                return LyricsSource.Line(start: TimeInterval(start) / 1000 + offset, text: (line.value ?? "").trimmingCharacters(in: .whitespaces))
            }
            if LyricsTimeline(timed: lines.map { ($0.start, $0.text) }) != nil { return .synced(lines) }
        }
        if let plain = sets.first(where: hasText) {
            let text = plain.line
                .map { ($0.value ?? "").trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return .plain(text) }
        }
        return nil
    }
}

/// Just enough of the LRC format (`[mm:ss.xx]text`, several timestamps per line allowed) to read
/// the timestamps some servers leave in the plain-text lyrics.
private enum LRC {
    static func parse(_ text: String) -> LyricsSource? {
        let tag = /\[(\d+):(\d+(?:\.\d+)?)\]/
        var timed: [(TimeInterval, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let stamps = line.matches(of: tag)
            guard !stamps.isEmpty else { continue }
            let body = line.replacing(tag, with: "").trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                guard let minutes = Double(stamp.output.1), let seconds = Double(stamp.output.2) else { continue }
                timed.append((minutes * 60 + seconds, body))
            }
        }
        guard LyricsTimeline(timed: timed) != nil else { return nil }
        return .synced(timed.map { LyricsSource.Line(start: $0.0, text: $0.1) })
    }
}
