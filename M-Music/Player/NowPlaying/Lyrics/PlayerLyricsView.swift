import SwiftUI

/// The song's lyrics, shown in the expanded player in place of the big artwork — the lyrics
/// counterpart of `PlayerQueueList`, hosted by `RegularChrome` the same way (and so with the same
/// top and bottom fades). Plain lyrics are scrollable text; synced lyrics are lines that follow
/// the song.
struct PlayerLyricsView: View {
    @ObservedObject private var player = PlayerManager.shared
    /// Width of the screen this sits on — see `SyncedLyricsView`.
    var width: CGFloat
    /// The room the panel has, so synced lyrics can scroll their last line up to the top.
    var panelHeight: CGFloat

    @State private var lyrics: TrackLyrics?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            // Re-run for every new song, so the lyrics follow the track while the panel is open.
            .task(id: player.currentTrack?.id) {
                guard let track = player.currentTrack else {
                    lyrics = .unavailable
                    return
                }
                if let cached = LyricsLoader.cached(for: track) {
                    lyrics = cached
                    return
                }
                lyrics = nil
                lyrics = await LyricsLoader.lyrics(for: track)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics {
        case nil:
            ProgressView()
                .tint(Color.transparentWhite)
                .padding(.top, 48)
        case .synced(let lines):
            // Replaced, not updated, when the song changes: the scroll position and the current
            // line belong to one song's lines.
            SyncedLyricsView(lines: lines, width: width, panelHeight: panelHeight)
                .id(lines.first?.text)
        case .plain(let text):
            PlainLyricsView(text: text)
        case .unavailable:
            Text("Lyrics not available")
                .font(.body)
                .foregroundStyle(Color.transparentWhite)
                .padding(.top, 48)
        }
    }
}

/// Lyrics without timing: plain text, scrolling.
private struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .lineSpacing(5)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.top, PlayerQueueList.FadeMask.topFade, for: .scrollContent)
        .contentMargins(.bottom, PlayerQueueList.FadeMask.bottomFade, for: .scrollContent)
        .mask { PlayerQueueList.TopFade() }
    }
}

/// Lyrics with timing: the sung lines, the current one white and slightly larger and at the top
/// of the view, the others fainter and blurrier the further they are from it. The view scrolls
/// itself as the song plays, and tapping a line seeks to it; while the user scrolls them it stops,
/// and every line but the current one looks alike, until they've been left alone for a few
/// seconds. An empty line is an instrumental break, drawn as three dots — but only while it is the current line: it appears when the break
/// begins and is gone again when the next line comes, so scrolling through the lyrics never shows
/// one.
private struct SyncedLyricsView: View {
    let lines: [SyncedLyricLine]
    let width: CGFloat
    let panelHeight: CGFloat

    @State private var currentIndex = 0
    @State private var hasScrolledInitially = false
    /// The break whose dots are leaving, or have left — kept after they've gone, so that while
    /// the line is fading out of the layout the dots stay gone rather than coming back for it.
    @State private var breakEnding: BreakEnding?
    /// How long the next scroll should take, when it isn't the usual `scrollDuration`: set by a
    /// break handing over to the next line, whose timing it adjusts to the break's length.
    @State private var scrollDurationOverride: TimeInterval?
    /// The song's position, kept between the twice-a-second updates — see `PlaybackClock`.
    @State private var clock = PlaybackClock()
    /// The user is looking around the lyrics (they scrolled them, and it hasn't been
    /// `browsingTimeout` since they stopped): the view stops following the song and shows every
    /// line but the current one alike, as the one after it looks.
    @State private var isBrowsing = false
    /// A finger is on the lyrics, or they're still coasting from a flick.
    @State private var isUserScrolling = false

    /// How long the lyrics have to be left alone before they go back to following the song.
    private static let browsingTimeout: TimeInterval = 5

    /// How much larger the current line is drawn.
    private static let currentScale: CGFloat = 1.1
    /// How long a finished break's dots take to grow from wherever their pulse has them to its
    /// largest size.
    private static let breakGrowDuration: TimeInterval = 1.0
    /// How long they then take to shrink away.
    private static let breakExitDuration: TimeInterval = 0.35
    /// How long the scroll to a line takes.
    private static let scrollDuration: TimeInterval = 0.6
    /// The least time the dots are left alone, pulsing, before they start to leave.
    private static let breakMinDwell: TimeInterval = 0.3
    /// The shortest the dots' leaving can be squeezed to, as a fraction of its usual length. A
    /// break too short for that gets no leaving animation.
    private static let breakMinCompression = 0.4

    /// The three steps by which a break hands over to the next line — the dots grow, the dots
    /// shrink away, the scroll runs — fitted to the time there is. Their total (`lead`) is how long
    /// before the next line's timestamp the dots start to leave, so that the scroll ends with the
    /// line at the top exactly at its timestamp. A break shorter than all that has the three
    /// squeezed together; one much shorter has none (`nil`).
    struct BreakTimings: Equatable {
        let grow: TimeInterval
        let exit: TimeInterval
        let scroll: TimeInterval
        var lead: TimeInterval { grow + exit + scroll }
    }

    fileprivate static func breakTimings(available: TimeInterval) -> BreakTimings? {
        let full = breakGrowDuration + breakExitDuration + scrollDuration
        let fraction = min(1, (available - breakMinDwell) / full)
        guard fraction >= breakMinCompression else { return nil }
        return BreakTimings(
            grow: breakGrowDuration * fraction,
            exit: breakExitDuration * fraction,
            scroll: scrollDuration * fraction
        )
    }

    /// A break whose dots are leaving.
    struct BreakEnding: Equatable {
        let index: Int
        let since: Date
        let timings: BreakTimings
    }

    var body: some View {
        // Distances are counted in sung lines, since the breaks between them aren't there to be
        // counted unless one is current.
        let textBefore = Self.textLinesBefore(lines)
        let current = min(currentIndex, lines.count - 1)
        let currentPosition = Double(textBefore[current]) - (lines[current].isBreak ? 0.5 : 0)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        if !line.isBreak {
                            let distance = Int(abs(Double(textBefore[line.id]) - currentPosition).rounded(.up))
                            LyricLineView(
                                text: line.text,
                                // Browsing, every line but the current one looks like the next,
                                // and none is blurred.
                                distance: isBrowsing ? min(distance, 1) : distance,
                                isBlurred: !isBrowsing,
                                scale: Self.currentScale
                            )
                            .id(line.id)
                            // The line is laid out narrower, so that scaled up it still ends where
                            // the others do instead of poking out past the right margin.
                            .padding(.trailing, unusedWidthWhenScaled)
                            // Tapping a line plays from it. The whole row takes the tap, not just
                            // the glyphs; a drag on it still scrolls.
                            .contentShape(.rect)
                            .onTapGesture {
                                // The view follows the song again, from the line that was tapped.
                                isBrowsing = false
                                PlayerManager.shared.seek(to: line.start)
                            }
                        } else if line.id == current {
                            let next = nextStart(after: line)
                            // The dots fill up by the time they start to leave.
                            LyricBreakDots(
                                start: line.start,
                                end: next.map { $0 - (Self.breakTimings(available: $0 - line.start)?.lead ?? 0) },
                                ending: breakEnding?.index == line.id ? breakEnding : nil
                            )
                            .id(line.id)
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
                // Lets a break make room for itself, and give it back, as it begins and ends.
                .animation(.smooth(duration: 0.5), value: currentIndex)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, PlayerQueueList.FadeMask.topFade, for: .scrollContent)
            // Room to scroll the last line all the way to the top.
            .contentMargins(.bottom, max(panelHeight, PlayerQueueList.FadeMask.bottomFade), for: .scrollContent)
            .mask { PlayerQueueList.TopFade() }
            // The user's own scrolling, as opposed to this view's: that's `.animating`.
            .onScrollPhaseChange { _, phase in
                switch phase {
                // Not `.tracking`, which is a finger that has touched the lyrics but hasn't moved
                // them (yet) — a tap on a line starts out like that.
                case .interacting, .decelerating:
                    isBrowsing = true
                    isUserScrolling = true
                case .idle:
                    isUserScrolling = false
                case .tracking, .animating:
                    break
                @unknown default:
                    break
                }
            }
            // Once they've been left alone long enough, back to the current line. Restarts, or is
            // cancelled, whenever the scrolling does.
            .task(id: isUserScrolling) {
                guard isBrowsing, !isUserScrolling else { return }
                try? await Task.sleep(for: .seconds(Self.browsingTimeout))
                guard !Task.isCancelled else { return }
                isBrowsing = false
                withAnimation(.smooth(duration: Self.scrollDuration)) { proxy.scrollTo(currentIndex, anchor: .top) }
            }
            .onReceive(PlaybackProgress.shared.$currentTime) { time in
                clock.update(time)
                let index = index(at: time)
                guard index != currentIndex else { return }
                // Moving on to the next line is `advance()`'s job, which times it to the
                // fraction of a second so the line gets to the top at its own timestamp; these
                // updates, twice a second, only catch what it doesn't: a seek, or the first
                // position when the view appears.
                if index == currentIndex + 1 { return }
                currentIndex = index
            }
            .task(id: currentIndex) { await advance() }
            // Scrolls to the line the moment it becomes current. The first scroll — to wherever
            // the song already is — is a jump, not a glide from the top.
            .onChange(of: currentIndex) {
                // A break that's current again starts afresh, whatever happened to it before.
                if lines[min(currentIndex, lines.count - 1)].isBreak { breakEnding = nil }
                let duration = scrollDurationOverride ?? Self.scrollDuration
                scrollDurationOverride = nil
                if isBrowsing {
                    // Leave the user's scrolling alone; the view catches up when they're done.
                } else if hasScrolledInitially {
                    withAnimation(.smooth(duration: duration)) { proxy.scrollTo(currentIndex, anchor: .top) }
                } else {
                    proxy.scrollTo(currentIndex, anchor: .top)
                    hasScrolledInitially = true
                }
            }
            .onAppear {
                // `onReceive` has already set the index by the time this runs, when the song is
                // past the first line.
                proxy.scrollTo(currentIndex, anchor: .top)
                hasScrolledInitially = true
            }
        }
    }

    /// Moves on from the current line to the next one, when it's time: the scroll to a line starts
    /// early enough to end with the line at the top exactly at its timestamp. The wait follows the
    /// song's position as `clock` estimates it, so it holds through pauses and seeks (a seek that
    /// lands elsewhere changes `currentIndex`, which cancels this).
    private func advance() async {
        let index = min(currentIndex, lines.count - 1)
        guard lines.indices.contains(index + 1) else { return }
        if lines[index].isBreak {
            await leaveBreak(at: index)
        } else {
            guard await waitUntil(effectiveStart(of: index + 1)) == .reached else { return }
            handOver(from: index, scrollDuration: scrollDuration(into: index + 1))
        }
    }

    /// A break's dots leave before the lyrics move on: they grow, then shrink away, and then the
    /// scroll runs, so that it ends with the next line at the top exactly at its timestamp.
    private func leaveBreak(at index: Int) async {
        let next = lines[index + 1].start
        guard let timings = Self.breakTimings(available: next - clock.estimate()) else {
            // Too little of the break is left to animate (the lyrics were opened, or the song
            // sought, to near its end): just wait it out.
            guard await waitUntil(next - 0.1) == .reached else { return }
            handOver(from: index, scrollDuration: nil)
            return
        }
        // The dots leave when the song gets within `lead` of the next line, and the lyrics move
        // on when it gets within `scroll` of it. Those are the song's times, not the clock's: if
        // it pauses or stalls while the dots are leaving, the lyrics wait with it.
        while true {
            guard await waitUntil(next - timings.lead) == .reached else { return }
            breakEnding = BreakEnding(index: index, since: Date(), timings: timings)
            try? await Task.sleep(for: .seconds(timings.grow + timings.exit))
            // Sought back to well before the end of the break: it has to start leaving again.
            switch await waitUntil(next - timings.scroll, abandonedBefore: next - timings.lead - 0.5) {
            case .reached:
                handOver(from: index, scrollDuration: timings.scroll)
                return
            case .cancelled:
                return
            case .soughtBack:
                breakEnding = nil
            }
        }
    }

    private enum Wait { case reached, cancelled, soughtBack }

    /// Waits until the song reaches `time`, as `clock` estimates it, to within the timer's
    /// accuracy: sleeps in short steps, the last of them just as long as what's left.
    private func waitUntil(_ time: TimeInterval, abandonedBefore floor: TimeInterval? = nil) async -> Wait {
        while true {
            let now = clock.estimate()
            if let floor, now < floor { return .soughtBack }
            let remaining = time - now
            if remaining <= 0 { return .reached }
            try? await Task.sleep(for: .seconds(min(remaining, 0.04)))
            if Task.isCancelled { return .cancelled }
        }
    }

    /// Moves on from the line at `index`. Always to at least the line after it, whatever the clock
    /// says, and never to an earlier one.
    private func handOver(from index: Int, scrollDuration: TimeInterval?) {
        scrollDurationOverride = scrollDuration
        currentIndex = max(index + 1, self.index(at: clock.estimate()))
    }

    /// For each line, how many sung (non-break) lines come before it.
    private static func textLinesBefore(_ lines: [SyncedLyricLine]) -> [Int] {
        var count = 0
        return lines.map { line in
            defer { if !line.isBreak { count += 1 } }
            return count
        }
    }

    /// The last line that has started by `time`; before the first one, the first. A line counts as
    /// started when the scroll to it begins (see `effectiveStart(of:)`) — that's when the lyrics
    /// move on to it, and if this disagreed, the next update would pull them back.
    private func index(at time: TimeInterval) -> Int {
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if effectiveStart(of: mid) <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// When the lyrics move on to a line: early enough that the scroll, which takes
    /// `scrollDuration(into:)`, ends with the line at the top exactly at its timestamp. A break
    /// appears at its timestamp — its dots show up where the sung line ends, not before.
    private func effectiveStart(of index: Int) -> TimeInterval {
        guard index > 0, !lines[index].isBreak else { return lines[index].start }
        return lines[index].start - (scrollDuration(into: index) ?? 0)
    }

    /// How long the scroll to the line at `index` takes: the usual time, shortened to fit when the
    /// previous line is closer than that, or the break before it is short (see `breakTimings`).
    private func scrollDuration(into index: Int) -> TimeInterval? {
        guard index > 0, !lines[index].isBreak else { return nil }
        let gap = lines[index].start - lines[index - 1].start
        if lines[index - 1].isBreak { return Self.breakTimings(available: gap)?.scroll }
        return min(Self.scrollDuration, gap)
    }

    private func nextStart(after line: SyncedLyricLine) -> TimeInterval? {
        lines.indices.contains(line.id + 1) ? lines[line.id + 1].start : nil
    }

    private var unusedWidthWhenScaled: CGFloat {
        (width - NowPlayingLayout.cardPaddings * 2) * (1 - 1 / Self.currentScale)
    }
}

/// One sung line of synced lyrics.
private struct LyricLineView: View {
    let text: String
    /// How many sung lines away from the current one this is; 0 for the current line.
    let distance: Int
    /// Whether the lines further from the current one are blurred; off while the user scrolls.
    let isBlurred: Bool
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(distance == 0 ? Color.white : Color.white.opacity(Self.opacity(forDistance: distance)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(distance == 0 ? scale : 1, anchor: .leading)
            .blur(radius: isBlurred ? Self.blur(forDistance: distance) : 0)
            .animation(.smooth(duration: 0.5), value: distance)
            .animation(.smooth(duration: 0.5), value: isBlurred)
    }

    /// Fainter with distance from the current line, down to a floor that keeps far lines legible.
    private static func opacity(forDistance distance: Int) -> Double {
        max(0.14, 0.55 - 0.09 * Double(distance - 1))
    }

    private static func blur(forDistance distance: Int) -> CGFloat {
        CGFloat(min(distance, 5)) * 1.1
    }
}

/// An instrumental break: three dots that fill with white, one after another, over the break's
/// length, and slowly pulse around the middle one. When the break ends they first grow, smoothly,
/// from wherever the pulse has them to its largest size, and then shrink away to nothing as they
/// fade out. Only exists while the break is current, so it reads the song's time itself — nothing
/// else re-renders on every tick for it.
private struct LyricBreakDots: View {
    let start: TimeInterval
    /// When the dots should be full; `nil` for a break at the very end, which fill over the rest
    /// of the song.
    let end: TimeInterval?
    /// How the dots are leaving, once the break is over; `nil` while it's still going.
    let ending: SyncedLyricsView.BreakEnding?

    @ObservedObject private var progress = PlaybackProgress.shared
    @State private var appearedAt = Date()

    private static let pulseMaxScale: CGFloat = 1.18
    /// One full swell and relaxation of the pulse.
    private static let pulsePeriod: TimeInterval = 3.2

    var body: some View {
        // A break at the end runs for as long as the song has left; guard against a missing or
        // backwards duration.
        let finish = max(end ?? progress.duration, start + 1)
        let fraction = min(max((progress.currentTime - start) / (finish - start), 0), 1)
        // The pulse is a function of time, rather than a repeating animation, so that the grow
        // at the end can pick it up from wherever it happens to be.
        TimelineView(.animation) { context in
            let (scale, opacity) = scaleAndOpacity(at: context.date)
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(max(fraction * 3 - Double(index), 0), 1)
                    Circle()
                        .fill(Color.white.opacity(0.28 + 0.72 * fill))
                        .frame(width: 11, height: 11)
                }
            }
            .animation(.linear(duration: 0.5), value: fraction)
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }

    private func pulseScale(after elapsed: TimeInterval) -> CGFloat {
        let swell = (1 - cos(2 * .pi * elapsed / Self.pulsePeriod)) / 2
        return 1 + (Self.pulseMaxScale - 1) * CGFloat(swell)
    }

    private func scaleAndOpacity(at date: Date) -> (CGFloat, Double) {
        guard let ending else { return (pulseScale(after: date.timeIntervalSince(appearedAt)), 1) }
        let elapsed = date.timeIntervalSince(ending.since)
        let grow = ending.timings.grow
        if elapsed < grow {
            // Eased at both ends, from the pulse's size at the moment the break ended.
            let progress = elapsed / grow
            let eased = progress * progress * (3 - 2 * progress)
            let from = pulseScale(after: ending.since.timeIntervalSince(appearedAt))
            return (from + (Self.pulseMaxScale - from) * CGFloat(eased), 1)
        }
        let progress = min((elapsed - grow) / ending.timings.exit, 1)
        let eased = progress * progress
        return (Self.pulseMaxScale + (0.01 - Self.pulseMaxScale) * CGFloat(eased), 1 - eased)
    }
}

/// The song's position as of the last update, carried forward by the clock while playing — the
/// updates come only twice a second, too coarsely to time a hand-over to the nearest frame.
/// Not observable: it's read by timers, not by rendering.
///
/// It only carries the position forward a little: while the song is playing the next update is
/// never more than half a second away, so anything longer means no updates are coming — a
/// restored song that was just given Play and hasn't started yet, or a stall — and then the
/// position is where the last update left it, not wherever the clock has got to. (Carried forward
/// without limit, a song paused for a minute with the lyrics open "played" a minute the moment
/// Play was pressed, and the lyrics ran ahead until the first real update pulled them back.)
private final class PlaybackClock {
    private var time: TimeInterval = 0
    private var updatedAt = Date()

    /// A little over the updates' interval, to allow for one that's a bit late.
    private static let maxExtrapolation: TimeInterval = 0.75

    func update(_ time: TimeInterval) {
        self.time = time
        updatedAt = Date()
    }

    @MainActor func estimate() -> TimeInterval {
        guard PlayerManager.shared.isPlaying else { return time }
        return time + min(Date().timeIntervalSince(updatedAt), Self.maxExtrapolation)
    }
}
