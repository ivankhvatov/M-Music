import Combine
import Foundation

/// Keeps the synced lyrics in step with the song, off the main actor: the clock, which line is
/// current, when a break's dots start to leave and when the lyrics move on, what the user's
/// scrolling and tapping do. All of it lives here, as plain state of an actor and `Task.sleep`s to
/// the moments things have to happen — nothing polls — and it writes to `LyricsModel` only when
/// something the views draw has changed.
///
/// Its inputs arrive as `Event`s, through an `AsyncStream` so they're handled in the order they
/// happened: the song's position, play/pause and track from `LyricsFeed`, and the user's scrolling
/// and taps from the views.
actor LyricsConductor {
    enum Event: Sendable {
        case position(TimeInterval)
        case playing(Bool)
        case duration(TimeInterval)
        /// The current track changed (`nil`: nothing, or radio). `prefetch`: the expanded player is
        /// up, so its lyrics will probably be asked for soon.
        case track(Child?, prefetch: Bool)
        /// The lyrics panel came up (`width` is the screen's) or went away.
        case activate(Bool, width: CGFloat)
        /// The user's finger is on the lyrics, or they're coasting (`true`); they've stopped.
        case scrollPhase(isUser: Bool)
        /// A line was tapped, and the song is being sought to `time`, its timestamp.
        case tap(Int, time: TimeInterval)
    }

    @MainActor static let shared: LyricsConductor = {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let feed = LyricsFeed(continuation: continuation)
        return LyricsConductor(stream: stream, continuation: continuation, model: .shared, feed: feed)
    }()

    private let model: LyricsModel
    private let continuation: AsyncStream<Event>.Continuation
    /// Held so its subscriptions live as long as this does.
    private let feed: LyricsFeed

    // The panel and the song.
    private var active = false
    private var trackID: String?
    private var currentTrack: Child?
    private var timeline: LyricsTimeline?
    /// The width the lines' text is laid out in.
    private var textWidth: CGFloat = 300
    private var current = 0

    // The playback clock: the position at the last update and when that was.
    private var anchorTime: TimeInterval = 0
    private var anchorInstant = ContinuousClock.now
    private var isPlaying = false
    private var duration: TimeInterval = 0

    // What's in progress.
    private var breakEnding: BreakEnding?
    private var tappedLine: Int?
    private var browsing = false

    private var loadTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var tapTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?

    /// How long the lyrics have to be left alone before they go back to following the song.
    private static let browsingTimeout: TimeInterval = 5
    /// How many lines away counts as a jump rather than a scroll.
    private static let farJump = 6
    /// How far the position may be from where the clock had it before it counts as a seek.
    private static let seekThreshold: TimeInterval = 0.35

    init(stream: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation, model: LyricsModel, feed: LyricsFeed) {
        self.model = model
        self.continuation = continuation
        self.feed = feed
        Task { await self.run(stream) }
    }

    /// Queues an event; callable from anywhere.
    nonisolated func send(_ event: Event) {
        continuation.yield(event)
    }

    private func run(_ stream: AsyncStream<Event>) async {
        for await event in stream { await handle(event) }
    }

    // MARK: - Events

    private func handle(_ event: Event) async {
        switch event {
        case .position(let time): await positionChanged(time)
        case .playing(let playing): await playingChanged(playing)
        case .duration(let value):
            duration = value
            if isShowingBreak { await publishClock() }
        case .track(let track, let prefetch): await trackChanged(track, prefetch: prefetch)
        case .activate(let isActive, let width): await activate(isActive, width: width)
        case .scrollPhase(let isUser): await scrollPhase(isUser: isUser)
        case .tap(let line, let time): await tap(line, time: time)
        }
    }

    private func positionChanged(_ time: TimeInterval) async {
        let expected = estimate()
        anchorTime = time
        anchorInstant = .now
        guard active, let timeline else { return }
        if isShowingBreak { await publishClock() }
        let jumped = abs(time - expected) > Self.seekThreshold
        let index = timeline.index(at: time)
        if index != current {
            // Moving on to the next line is `advance()`'s job, which times it to the fraction of a
            // second so the line gets to the top at its own timestamp; these updates, twice a
            // second, only catch what it doesn't: a seek.
            if index == current + 1 || tappedLine != nil {
                if jumped { await restartAdvance() }
                return
            }
            await setCurrent(index, scrollDuration: LyricsTimeline.scrollDuration)
            return
        }
        if jumped { await restartAdvance() }
    }

    private func playingChanged(_ playing: Bool) async {
        anchorTime = estimate()
        anchorInstant = .now
        isPlaying = playing
        if isShowingBreak { await publishClock() }
        await restartAdvance()
    }

    private func trackChanged(_ track: Child?, prefetch: Bool) async {
        guard track?.id.raw != trackID else { return }
        trackID = track?.id.raw
        currentTrack = track
        cancelEverything()
        timeline = nil
        current = 0
        guard let track else {
            if active { await model.setPhase(.unavailable) }
            return
        }
        if active {
            await begin(track)
        } else if prefetch {
            await LyricsLoader.shared.prefetch(track)
        }
    }

    private func activate(_ isActive: Bool, width: CGFloat) async {
        textWidth = LyricsLayout.textWidth(forViewWidth: width)
        guard active != isActive else { return }
        active = isActive
        if isActive {
            if let currentTrack {
                await begin(currentTrack)
            } else {
                await model.setPhase(.unavailable)
            }
        } else {
            cancelEverything()
            timeline = nil
            await model.setPhase(.idle)
        }
    }

    /// Gets the track's lyrics onto the screen: at once if they're already fetched, with a spinner
    /// until they are if not.
    private func begin(_ track: Child) async {
        loadTask?.cancel()
        if let cached = await LyricsLoader.shared.cached(for: track) {
            await loaded(cached, trackID: track.id.raw)
            return
        }
        await model.setPhase(.loading)
        loadTask = Task {
            let lyrics = await LyricsLoader.shared.lyrics(for: track)
            guard !Task.isCancelled else { return }
            await self.loaded(lyrics, trackID: track.id.raw)
        }
    }

    private func loaded(_ lyrics: TrackLyrics, trackID id: String) async {
        guard active, id == trackID else { return }
        switch lyrics {
        case .synced(let timeline):
            self.timeline = timeline
            current = timeline.index(at: estimate())
            if timeline.lines[current].isBreak { await publishClock() }
            // Measured here, off the main actor, rather than by the views as they build.
            await model.showSynced(timeline, LyricsLayout(timeline: timeline, textWidth: textWidth), at: current)
            scheduleAdvance()
            // The panel is still sliding in; once it has settled, the rows the first frame left
            // out — the ones a flick would want — are built, a row at a time, when nothing is
            // moving.
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                while !Task.isCancelled, self.timeline == timeline {
                    if await self.model.growWindowAroundCurrent() { break }
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        case .plain(let text):
            await model.setPhase(.plain(text))
        case .unavailable:
            await model.setPhase(.unavailable)
        }
    }

    private func scrollPhase(isUser: Bool) async {
        if isUser {
            browseTask?.cancel()
            guard !browsing else { return }
            browsing = true
            await model.setBrowsing(true)
        } else if browsing {
            // Once they've been left alone long enough, back to the current line.
            browseTask?.cancel()
            browseTask = Task {
                try? await Task.sleep(for: .seconds(Self.browsingTimeout))
                guard !Task.isCancelled else { return }
                await self.stopBrowsing(scrollBack: true)
            }
        }
    }

    private func stopBrowsing(scrollBack: Bool) async {
        browseTask?.cancel()
        guard browsing else { return }
        browsing = false
        await model.setBrowsing(false)
        if scrollBack { await model.requestScroll(to: current, duration: LyricsTimeline.scrollDuration) }
    }

    /// A tap on a line: the song is being sought to it, and the lyrics follow. A break that's
    /// showing has its dots shrink away first, at once and from wherever the pulse has them, and
    /// then the lyrics move — the break's own hand-over, which would otherwise do that, plays out
    /// its dots' grow too.
    private func tap(_ line: Int, time: TimeInterval) async {
        // The seek's own position update is queued behind this, so until it arrives the clock
        // would still say wherever the song was — and anything scheduled from here (the line this
        // makes current is followed by an `advance()`) would act on that, moving the lyrics back
        // to the line that was current before the tap. The song is going to `time`: the clock
        // goes there now.
        anchorTime = time
        anchorInstant = .now
        await stopBrowsing(scrollBack: false)
        guard active, let timeline else { return }
        let index = min(current, timeline.count - 1)
        guard timeline.lines[index].isBreak, breakEnding?.index != index else {
            tappedLine = nil
            await setCurrent(line, scrollDuration: LyricsTimeline.scrollDuration)
            return
        }
        tappedLine = line
        advanceTask?.cancel()
        await setBreakEnding(
            index,
            BreakTimings(grow: 0, exit: LyricsTimeline.breakExitDuration, scroll: 0)
        )
        tapTask?.cancel()
        tapTask = Task {
            try? await Task.sleep(for: .seconds(LyricsTimeline.breakExitDuration))
            // Not if another tap has taken over in the meantime.
            guard !Task.isCancelled, await self.tappedLine == line else { return }
            await self.finishTap(line)
        }
    }

    private func finishTap(_ line: Int) async {
        guard tappedLine == line else { return }
        tappedLine = nil
        await setCurrent(line, scrollDuration: LyricsTimeline.scrollDuration)
    }

    // MARK: - The current line

    private var isShowingBreak: Bool {
        guard let timeline, active, timeline.lines.indices.contains(current) else { return false }
        return timeline.lines[current].isBreak
    }

    private func setCurrent(_ index: Int, scrollDuration: TimeInterval?) async {
        guard let timeline else { return }
        let previous = current
        current = index
        if timeline.lines[index].isBreak {
            // A break that's current again starts afresh, whatever happened to it before.
            breakEnding = nil
            await model.setBreakEnding(nil)
            await publishClock()
        }
        // Far from where it was (a seek) the lyrics jump, rather than run past all the lines between.
        let far = abs(index - previous) > Self.farJump
        let scroll: LyricsModel.ScrollRequest.Mode = browsing ? .none : (far ? .jump : .animated(scrollDuration ?? LyricsTimeline.scrollDuration))
        await model.setCurrent(index, scroll: scroll)
        scheduleAdvance()
    }

    private func setBreakEnding(_ index: Int, _ timings: BreakTimings) async {
        let ending = BreakEnding(index: index, since: Date(), timings: timings)
        breakEnding = ending
        await model.setBreakEnding(ending)
    }

    private func publishClock() async {
        let elapsed = anchorInstant.duration(to: .now).seconds
        await model.setClock(.init(
            time: anchorTime,
            wall: Date(timeIntervalSinceNow: -elapsed),
            isPlaying: isPlaying,
            duration: duration
        ))
    }

    // MARK: - Moving on

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard active, let timeline else { return }
        advanceTask = Task { await self.advance(timeline) }
    }

    /// The clock jumped (a seek, a pause, a resume): whatever `advance()` was waiting for has
    /// moved, so it starts again — except that a break whose dots had begun to leave, and which the
    /// song was then sought back from, starts over.
    private func restartAdvance() async {
        guard active, let timeline else { return }
        if let ending = breakEnding, ending.index == current, let next = timeline.nextStart(after: current),
           estimate() < next - ending.timings.lead - 0.5 {
            breakEnding = nil
            await model.setBreakEnding(nil)
        }
        scheduleAdvance()
    }

    /// Moves on from the current line to the next one, when it's time: the scroll to a line starts
    /// early enough to end with the line at the top exactly at its timestamp. The wait follows the
    /// song's position as the clock estimates it.
    private func advance(_ timeline: LyricsTimeline) async {
        let index = min(current, timeline.count - 1)
        guard timeline.lines.indices.contains(index + 1) else { return }
        if timeline.lines[index].isBreak {
            await leaveBreak(at: index, timeline)
        } else {
            guard await waitUntil(timeline.effectiveStart(of: index + 1)) else { return }
            await handOver(from: index, scrollDuration: timeline.scrollDurations[index + 1], timeline)
        }
    }

    /// A break's dots leave before the lyrics move on: they grow, then shrink away, and then the
    /// scroll runs, so that it ends with the next line at the top exactly at its timestamp.
    private func leaveBreak(at index: Int, _ timeline: LyricsTimeline) async {
        let next = timeline.lines[index + 1].start
        guard let timings = LyricsTimeline.breakTimings(available: next - estimate()) else {
            // Too little of the break is left to animate (the lyrics were opened, or the song
            // sought, to near its end): just wait it out.
            guard await waitUntil(next - 0.1), tappedLine == nil else { return }
            await handOver(from: index, scrollDuration: nil, timeline)
            return
        }
        // The dots leave when the song gets within `lead` of the next line, and the lyrics move on
        // when it gets within `scroll` of it. Those are the song's times, not the wall clock's: if
        // it pauses or stalls while the dots are leaving, the lyrics wait with it.
        guard await waitUntil(next - timings.lead), tappedLine == nil else { return }
        await setBreakEnding(index, timings)
        try? await Task.sleep(for: .seconds(timings.grow + timings.exit))
        guard !Task.isCancelled, await waitUntil(next - timings.scroll) else { return }
        if tappedLine == nil { await handOver(from: index, scrollDuration: timings.scroll, timeline) }
    }

    /// Moves on from the line at `index`. Always to at least the line after it, whatever the clock
    /// says, and never to an earlier one.
    private func handOver(from index: Int, scrollDuration: TimeInterval?, _ timeline: LyricsTimeline) async {
        // Not if something else moved the lyrics (or restarted the schedule) in the meantime.
        guard !Task.isCancelled, current == index else { return }
        await setCurrent(max(index + 1, timeline.index(at: estimate())), scrollDuration: scrollDuration)
    }

    /// Waits until the song reaches `time`, as the clock estimates it, to within the timer's
    /// accuracy: one sleep to the moment while playing (the clock keeps being corrected by the
    /// updates meanwhile, so it re-checks on waking), a slow poll while paused. `false` if
    /// cancelled.
    private func waitUntil(_ time: TimeInterval) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let remaining = time - estimate()
            if remaining <= 0 { return true }
            try? await Task.sleep(for: .seconds(isPlaying ? min(remaining, 5) : 0.5))
        }
    }

    // MARK: - The clock

    /// The song's position now: as of the last update, carried forward a little while playing — the
    /// updates come only twice a second, too coarsely to time a hand-over to the nearest frame, but
    /// anything longer than one interval means none are coming (a restored song that was just given
    /// Play and hasn't started yet, or a stall), and then the position is where the last update left
    /// it, not wherever the wall clock has got to.
    private func estimate() -> TimeInterval {
        guard isPlaying else { return anchorTime }
        return anchorTime + min(anchorInstant.duration(to: .now).seconds, LyricsModel.ClockAnchor.maxExtrapolation)
    }

    private func cancelEverything() {
        loadTask?.cancel()
        advanceTask?.cancel()
        tapTask?.cancel()
        browseTask?.cancel()
        breakEnding = nil
        tappedLine = nil
        browsing = false
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Forwards the few things the lyrics need to know about playback — the position, whether it's
/// playing, the track — into the conductor's event stream. Set up once; the position comes twice
/// a second.
@MainActor
final class LyricsFeed {
    private var subscriptions = Set<AnyCancellable>()

    init(continuation: AsyncStream<LyricsConductor.Event>.Continuation) {
        let progress = PlaybackProgress.shared
        let player = PlayerManager.shared

        progress.$currentTime
            .sink { continuation.yield(.position($0)) }
            .store(in: &subscriptions)
        progress.$duration
            .removeDuplicates()
            .sink { continuation.yield(.duration($0)) }
            .store(in: &subscriptions)
        player.$isPlaying
            .removeDuplicates()
            .sink { continuation.yield(.playing($0)) }
            .store(in: &subscriptions)
        Publishers.CombineLatest(player.$currentIndex, player.$queue)
            .map { index, queue -> Child? in
                guard let index, queue.indices.contains(index) else { return nil }
                return queue[index]
            }
            .removeDuplicates { $0?.id == $1?.id }
            .sink { track in
                // While the expanded player is up, the lyrics will probably be asked for.
                let expanded = MainActor.assumeIsolated { PlayerPresentation.shared.expanded }
                continuation.yield(.track(track, prefetch: expanded))
            }
            .store(in: &subscriptions)
    }
}
