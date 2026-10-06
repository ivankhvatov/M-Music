import Foundation

/// One line of synced lyrics. An empty `text` is an instrumental break rather than a sung line.
struct SyncedLyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// Seconds from the start of the song.
    let start: TimeInterval
    let text: String

    var isBreak: Bool { text.isEmpty }
}

/// The three steps by which a break hands over to the next line — the dots grow, the dots shrink
/// away, the scroll runs — fitted to the time there is. Their total (`lead`) is how long before the
/// next line's timestamp the dots start to leave, so that the scroll ends with the line at the top
/// exactly at its timestamp.
struct BreakTimings: Equatable, Sendable {
    let grow: TimeInterval
    let exit: TimeInterval
    let scroll: TimeInterval
    var lead: TimeInterval { grow + exit + scroll }
}

/// A break whose dots are leaving.
struct BreakEnding: Equatable, Sendable {
    let index: Int
    let since: Date
    let timings: BreakTimings
}

/// Synced lyrics, with everything about their timing worked out once, off the main thread, when
/// they're loaded — so that nothing on screen has to derive it again for every line change.
struct LyricsTimeline: Equatable, Sendable {
    /// How long a finished break's dots take to grow from wherever their pulse has them to its
    /// largest size.
    static let breakGrowDuration: TimeInterval = 1.0
    /// How long they then take to shrink away.
    static let breakExitDuration: TimeInterval = 0.35
    /// How long the scroll to a line takes.
    static let scrollDuration: TimeInterval = 0.6
    /// The least time the dots are left alone, pulsing, before they start to leave.
    private static let breakMinDwell: TimeInterval = 0.3
    /// The shortest the dots' leaving can be squeezed to, as a fraction of its usual length. A
    /// break too short for that gets no leaving animation.
    private static let breakMinCompression = 0.4
    /// The shortest instrumental break that's shown, in seconds.
    private static let minBreakLength: TimeInterval = 1.5

    let lines: [SyncedLyricLine]
    /// For each line, how many sung (non-break) lines come before it.
    private let textBefore: [Int]
    /// When the lyrics move on to each line — see `effectiveStart(of:)`.
    private let effectiveStarts: [TimeInterval]
    /// How long the scroll into each line takes; `nil` for breaks and the first line.
    let scrollDurations: [TimeInterval?]
    /// Tells two songs' lyrics apart.
    let identity: String

    /// Sorts the lines by time, folds consecutive empty ones into a single break (dropping any too
    /// short to show, and any after the last sung line), and turns a long wait before the first sung
    /// line into a break of its own. `nil` if there's nothing sung.
    init?(timed: [(TimeInterval, String)]) {
        var raw: [(TimeInterval, String)] = []
        for item in timed.sorted(by: { $0.0 < $1.0 }) {
            if item.1.isEmpty, raw.last?.1.isEmpty == true { continue }
            raw.append(item)
        }
        // Nothing after the last sung line: no break once the lyrics have ended.
        while raw.last?.1.isEmpty == true { raw.removeLast() }
        // A break too short to show its dots, and hand over from them, isn't worth showing.
        raw = raw.enumerated().filter { index, line in
            guard line.1.isEmpty, raw.indices.contains(index + 1) else { return true }
            return raw[index + 1].0 - line.0 >= Self.minBreakLength
        }.map(\.element)
        guard let first = raw.first, raw.contains(where: { !$0.1.isEmpty }) else { return nil }
        if !first.1.isEmpty, first.0 >= 4 { raw.insert((0, ""), at: 0) }

        let lines = raw.enumerated().map {
            SyncedLyricLine(id: $0.offset, start: max(0, $0.element.0), text: $0.element.1)
        }
        var count = 0
        var textBefore: [Int] = []
        for line in lines {
            textBefore.append(count)
            if !line.isBreak { count += 1 }
        }
        var scrollDurations: [TimeInterval?] = []
        for (index, line) in lines.enumerated() {
            guard index > 0, !line.isBreak else {
                scrollDurations.append(nil)
                continue
            }
            let gap = line.start - lines[index - 1].start
            if lines[index - 1].isBreak {
                scrollDurations.append(Self.breakTimings(available: gap)?.scroll)
            } else {
                scrollDurations.append(min(Self.scrollDuration, gap))
            }
        }
        self.lines = lines
        self.textBefore = textBefore
        self.scrollDurations = scrollDurations
        self.effectiveStarts = lines.enumerated().map { index, line in
            // A break appears at its timestamp — its dots show up where the sung line ends, not
            // before; any other line is reached by a scroll that ends at its timestamp.
            line.start - (index > 0 && !line.isBreak ? (scrollDurations[index] ?? 0) : 0)
        }
        self.identity = "\(lines.count)|\(lines.first?.text ?? "")|\(lines.last?.start ?? 0)"
    }

    var count: Int { lines.count }

    /// The break timings for a stretch of `available` seconds; `nil` if that's too little to
    /// animate. A break shorter than the full sequence has the three steps squeezed together.
    static func breakTimings(available: TimeInterval) -> BreakTimings? {
        let full = breakGrowDuration + breakExitDuration + scrollDuration
        let fraction = min(1, (available - breakMinDwell) / full)
        guard fraction >= breakMinCompression else { return nil }
        return BreakTimings(
            grow: breakGrowDuration * fraction,
            exit: breakExitDuration * fraction,
            scroll: scrollDuration * fraction
        )
    }

    /// The last line that has started by `time`; before the first one, the first. A line counts as
    /// started when the scroll to it begins — that's when the lyrics move on to it, and if this
    /// disagreed, the next update would pull them back.
    func index(at time: TimeInterval) -> Int {
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if effectiveStarts[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// When the lyrics move on to the line at `index`.
    func effectiveStart(of index: Int) -> TimeInterval { effectiveStarts[index] }

    /// When the line after `index` starts, if there is one.
    func nextStart(after index: Int) -> TimeInterval? {
        lines.indices.contains(index + 1) ? lines[index + 1].start : nil
    }

    /// How far, in sung lines, the line at `index` is from the current line (0 for the current
    /// line). The breaks between sung lines aren't there to be counted unless one is current, in
    /// which case it counts as half a line.
    func distance(of index: Int, from current: Int) -> Int {
        let position = Double(textBefore[current]) - (lines[current].isBreak ? 0.5 : 0)
        return Int(abs(Double(textBefore[index]) - position).rounded(.up))
    }
}
