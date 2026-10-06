import Foundation

/// A song's lyrics as the lyrics panel shows them.
enum TrackLyrics: Equatable, Sendable {
    case synced(LyricsTimeline)
    case plain(String)
    case unavailable
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
            return result.lyrics
        }
        inFlight[id] = task
        return task
    }

    private func finish(id: String, result: (lyrics: TrackLyrics, isDefinitive: Bool)) {
        inFlight[id] = nil
        // A network failure isn't "no lyrics" — don't remember it, so the next open tries again.
        guard result.isDefinitive else { return }
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[id] = result.lyrics
    }

    private static func fetch(_ track: Child) async -> (lyrics: TrackLyrics, isDefinitive: Bool) {
        let client = SubsonicClient.shared
        var failed = false

        do {
            let sets = try await client.getLyricsBySongId(id: track.id.raw)
            if let found = choose(from: sets) { return (found, true) }
        } catch {
            failed = true
        }

        // Servers without `getLyricsBySongId` (or a song it has nothing for) may still answer the
        // older artist/title lookup, which gives plain text — occasionally LRC text.
        do {
            let legacy = try await client.getLyrics(artist: track.artist, title: track.title)
            if let text = legacy.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return (LRC.parse(text) ?? .plain(text), true)
            }
            failed = false
        } catch {
            failed = true
        }
        return (.unavailable, !failed)
    }

    /// Prefers a synced set that has any text, then a plain one.
    private static func choose(from sets: [StructuredLyrics]) -> TrackLyrics? {
        let hasText: (StructuredLyrics) -> Bool = { set in
            set.line.contains { !($0.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if let synced = sets.first(where: { $0.synced && hasText($0) }) {
            let offset = TimeInterval(synced.offset ?? 0) / 1000
            let timed = synced.line.compactMap { line -> (TimeInterval, String)? in
                guard let start = line.start else { return nil }
                return (TimeInterval(start) / 1000 + offset, (line.value ?? "").trimmingCharacters(in: .whitespaces))
            }
            if let timeline = LyricsTimeline(timed: timed) { return .synced(timeline) }
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
    static func parse(_ text: String) -> TrackLyrics? {
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
        return LyricsTimeline(timed: timed).map(TrackLyrics.synced)
    }
}
