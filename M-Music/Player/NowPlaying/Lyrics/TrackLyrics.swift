import Foundation

/// One line of synced lyrics. An empty `text` is an instrumental break rather than a sung line.
struct SyncedLyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// Seconds from the start of the song.
    let start: TimeInterval
    let text: String

    var isBreak: Bool { text.isEmpty }
}

/// A song's lyrics as the lyrics panel shows them.
enum TrackLyrics: Equatable, Sendable {
    case synced([SyncedLyricLine])
    case plain(String)
    case unavailable
}

/// Fetches lyrics and keeps what it found, so reopening the panel — or coming back to a song — is
/// instant. Main-actor only, like the views that read it.
@MainActor
enum LyricsLoader {
    private static var cache: [String: TrackLyrics] = [:]

    /// Already-fetched lyrics for a track, if any.
    static func cached(for track: Child) -> TrackLyrics? {
        cache[track.id.raw]
    }

    static func lyrics(for track: Child) async -> TrackLyrics {
        if let cached = cache[track.id.raw] { return cached }
        let client = SubsonicClient.shared
        var failed = false

        do {
            let sets = try await client.getLyricsBySongId(id: track.id.raw)
            if let found = Self.choose(from: sets) { return remember(found, for: track) }
        } catch {
            failed = true
        }

        // Servers without `getLyricsBySongId` (or a song it has nothing for) may still answer the
        // older artist/title lookup, which gives plain text — occasionally LRC text.
        do {
            let legacy = try await client.getLyrics(artist: track.artist, title: track.title)
            if let text = legacy.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                failed = false
                return remember(LRC.parse(text) ?? .plain(text), for: track)
            }
        } catch {
            failed = true
        }

        // A network failure isn't "no lyrics" — don't remember it, so the next open tries again.
        return failed ? .unavailable : remember(.unavailable, for: track)
    }

    private static func remember(_ lyrics: TrackLyrics, for track: Child) -> TrackLyrics {
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[track.id.raw] = lyrics
        return lyrics
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
            if let lines = syncedLines(from: timed) { return .synced(lines) }
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

    /// The shortest instrumental break that's shown, in seconds.
    private static let minBreakLength: TimeInterval = 1.5

    /// Sorts the lines by time, folds consecutive empty ones into a single break (dropping any too
    /// short to show), and turns a long wait before the first sung line into a break of its own.
    static func syncedLines(from timed: [(TimeInterval, String)]) -> [SyncedLyricLine]? {
        var lines: [(TimeInterval, String)] = []
        for item in timed.sorted(by: { $0.0 < $1.0 }) {
            if item.1.isEmpty, lines.last?.1.isEmpty == true { continue }
            lines.append(item)
        }
        // A break too short to show its dots, and hand over from them, isn't worth showing.
        lines = lines.enumerated().filter { index, line in
            guard line.1.isEmpty, lines.indices.contains(index + 1) else { return true }
            return lines[index + 1].0 - line.0 >= minBreakLength
        }.map(\.element)
        guard let first = lines.first, lines.contains(where: { !$0.1.isEmpty }) else { return nil }
        if !first.1.isEmpty, first.0 >= 4 { lines.insert((0, ""), at: 0) }
        return lines.enumerated().map { SyncedLyricLine(id: $0.offset, start: max(0, $0.element.0), text: $0.element.1) }
    }
}

/// Just enough of the LRC format (`[mm:ss.xx]text`, several timestamps per line allowed) to read
/// the timestamps some servers leave in the plain-text lyrics.
@MainActor
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
        return LyricsLoader.syncedLines(from: timed).map(TrackLyrics.synced)
    }
}
