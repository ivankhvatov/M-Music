import SwiftUI
import Observation

/// What the lyrics views draw, and what keeps them in step with the song.
///
/// Nothing here keeps a clock of its own. On every frame the song is playing, a `TimelineView` in
/// the lyrics asks the player where the song is (`PlayerManager.livePosition`) and `follow()` works
/// out from that alone which line is current and how a break's dots stand; it writes only when
/// something on screen actually changes — a line becomes current, a break's plan is made, the user
/// starts or stops browsing. A pause, a seek, a skip to another song, a relaunch into the middle of
/// a break are all just what the position says now, so there is nothing to get out of step.
/// `LyricsConductor` is left with loading the lyrics.
@MainActor
@Observable
final class LyricsModel {
    static let shared = LyricsModel()

    enum Phase {
        /// The panel isn't up.
        case idle
        case loading
        case synced(LyricsTimeline, LyricsLayout)
        case plain(String)
        case unavailable
    }

    /// A request for the synced lyrics to scroll somewhere; `generation` makes two requests for the
    /// same line distinct, so each is acted on.
    struct ScrollRequest: Equatable {
        var target = 0
        /// How long the scroll takes; `nil` for a jump.
        var duration: TimeInterval?
        /// A jump made after the song was sought far from where it was, which has to wait for the
        /// lines around the target to be laid out.
        var settles = false
        var generation = 0
    }

    /// How the current break's dots leave, worked out once when it became current (and again if
    /// the song is sought within it). `timings` is `nil` for a break that draws no dots: when it
    /// became current there was too little of it left for them to even shrink away, so they'd only
    /// have shown up as the next line moved in. The decision to draw them and the plan for them
    /// leaving are one, so dots that are drawn are always seen to leave, never just faded out by
    /// the next line moving in. The plan stays until another break becomes current, so that the
    /// row fading out doesn't bring dots back.
    struct BreakPlan: Equatable {
        let index: Int
        var timings: BreakTimings?
    }

    /// A tap during a break: its dots shrink away at once, in their own time, whether the song
    /// plays or not, and then the lyrics move to the tapped line.
    struct TapEnding: Equatable {
        let index: Int
        let since: Date
        /// The song's time at the tap, by which the dots' pulse is worked out, for the size they
        /// leave from.
        let pulseTime: TimeInterval
    }

    private(set) var phase: Phase = .idle
    /// Which song's lyrics the synced view is showing, or waiting for: it's the same view from the
    /// moment the lyrics start to load until they're replaced by another song's, so that it's there
    /// to take part in the panel's coming in (see `PlayerLyricsView`).
    private(set) var session = 0
    private(set) var currentIndex = 0
    /// The line whose room the layout makes: the current line's extra space above and below, or a
    /// break's dots. It's the current line, except while the user is browsing, when it stays where
    /// it was — otherwise every change of line would shift the lines under their finger.
    private(set) var layoutIndex = 0
    /// The lines that have rows built — see `LyricsLayout`.
    private(set) var window = LyricsLayout.Window()
    /// The user's finger is moving the lyrics, or they're coasting from a flick.
    private(set) var isUserScrolling = false
    private(set) var breakPlan: BreakPlan?
    private(set) var tapEnding: TapEnding?
    /// Whether a break's dots are leaving (so they're drawn at the full frame rate).
    private(set) var dotsEnding = false
    /// The user is looking around the lyrics: every line but the current one looks alike.
    private(set) var isBrowsing = false
    private(set) var scrollRequest = ScrollRequest()
    /// Whether the scroll view shows what's in it. Off while the lyrics load; on once they're there
    /// — for lyrics that arrive late, a moment after they were put in (see `reveal`).
    private(set) var revealsContent = false
    /// Whether the loading spinner is in the view. It stays a little past `revealsContent`, while
    /// it fades, and goes then — its visibility is that opacity, not the view's removal, which
    /// SwiftUI is not always sure to carry out.
    private(set) var showsSpinner = false

    /// The line a tap is moving the lyrics to, once the dots of the break that is current have
    /// shrunk away.
    @ObservationIgnored private var tapHold: Int?
    /// Off between another song starting and its lyrics (or none) being put in: the lyrics on
    /// screen are the previous song's, which the new song's position would only move about.
    @ObservationIgnored private var follows = false
    @ObservationIgnored private var isFollowing = false
    /// Where the song was, and when, at the last `follow()` — to tell a seek from playing on.
    @ObservationIgnored private var lastPosition: TimeInterval = 0
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private var tapTask: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var growTask: Task<Void, Never>?

    /// How long the lyrics have to be left alone before they go back to following the song.
    private static let browsingTimeout: TimeInterval = 5
    /// How many lines away counts as a jump rather than a scroll.
    private static let farJump = 6
    /// How far the position may be from where playing on would have it before it counts as a seek.
    private static let seekThreshold: TimeInterval = 0.35
    /// How long before the next line a break with no dots hands over to it.
    private static let dotlessHandOverLead: TimeInterval = 0.1

    /// Everything the views animate on a change of the current line or of browsing — line fades,
    /// the current line's extra room, a break's row appearing and going — rides this one
    /// animation, so only the rows that actually change animate.
    private static let changeAnimation = Animation.smooth(duration: 0.5)

    func setPhase(_ phase: Phase) {
        let wasLoading: Bool
        if case .loading = self.phase { wasLoading = true } else { wasLoading = false }
        let isShowing: Bool
        switch phase {
        case .idle, .loading: isShowing = false
        case .synced, .plain, .unavailable: isShowing = true
        }
        if !wasLoading { session += 1 }
        self.phase = phase
        if wasLoading && isShowing {
            reveal()
        } else {
            revealsContent = isShowing
            showsSpinner = { if case .loading = phase { true } else { false } }()
        }
        if case .synced = phase {} else {
            currentIndex = 0
            resetFollowing()
        }
    }

    /// Another song has started: its lyrics are on their way, and until they're there the previous
    /// song's stay as they are.
    func stopFollowing() {
        follows = false
    }

    /// Everything about following a song's lines, for lyrics that are gone or about to be replaced.
    private func resetFollowing() {
        follows = false
        tapTask?.cancel()
        browseTask?.cancel()
        growTask?.cancel()
        tapHold = nil
        tapEnding = nil
        breakPlan = nil
        dotsEnding = false
        isBrowsing = false
        lastDate = nil
    }

    /// Shows synced lyrics, positioned where the song is — in one step, so the lines never show
    /// with a previous song's current line.
    func showSynced(_ timeline: LyricsTimeline, _ layout: LyricsLayout) {
        let position = PlayerManager.shared.livePosition
        let index = timeline.index(at: position)
        resetFollowing()
        if case .loading = phase {
            // The lyrics arrive in the view that has been waiting for them.
            phase = .synced(timeline, layout)
            reveal()
        } else {
            session += 1
            phase = .synced(timeline, layout)
            revealsContent = true
            showsSpinner = false
        }
        currentIndex = index
        layoutIndex = index
        window = layout.initialWindow(around: index)
        if timeline.lines[index].isBreak {
            // Opened — or a restored song picked up — with the song in the middle of a break's
            // ending: the dots are where they would have been had they been showing all along.
            planBreak(at: index, position: position, timeline, restoring: true)
        }
        lastPosition = position
        lastDate = Date()
        follows = true
        updateDotsEnding(position: position, timeline)
        scrollRequest = ScrollRequest(target: index, duration: nil, generation: scrollRequest.generation + 1)
        // The panel is still sliding in; once it has settled, the rows the first frame left out —
        // the ones a flick would want — are built, a row at a time, when nothing is moving.
        growTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            while !Task.isCancelled, let self {
                if self.growWindowAroundCurrent() { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func setCurrent(_ index: Int, scroll: ScrollRequest.Mode) {
        withAnimation(Self.changeAnimation) {
            currentIndex = index
            if !isBrowsing { layoutIndex = index }
        }
        switch scroll {
        case .none:
            break
        case .jump:
            // The rows around where it's going are built before it gets there.
            if case .synced(_, let layout) = phase { window = layout.window(around: index) }
            scrollRequest = ScrollRequest(target: index, duration: nil, settles: true, generation: scrollRequest.generation + 1)
        case .animated(let duration):
            // The rows around where it's going are built before it starts, and the ones the song
            // has left behind are let go now — they can't be later, once it has arrived (see
            // `LyricsScrollView`).
            if case .synced(_, let layout) = phase { window = layout.window(around: index) }
            scrollRequest = ScrollRequest(target: index, duration: duration, generation: scrollRequest.generation + 1)
        }
    }

    /// Fades in what lyrics that were still loading turned out to be, with the panel's animation —
    /// in a turn of its own, after they've been put in the view. Animating that itself animated
    /// their layout too (the room taken by the lines far from the current one, growing from
    /// nothing), and the jump to the current line, made meanwhile, went by the half-grown layout
    /// and stopped short: the lyrics were there, but out of sight until they were scrolled.
    ///
    /// And not in the very next turn either, but a few frames on: with the lines put in and the
    /// fade started in one render, the text of plain lyrics (and the "not available" notice) was
    /// at times never drawn — the view laid out at its full size and empty, however long it was
    /// left — and showed only when the lyrics were closed and opened again. The fade starts once
    /// the content has been drawn, at nothing.
    private func reveal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            // Closed, or replaced by another song's lyrics, in the meantime.
            switch phase {
            case .idle, .loading: return
            case .synced, .plain, .unavailable: break
            }
            withAnimation(.playerQueueAnimation) { revealsContent = true }
            // Once it has faded.
            try? await Task.sleep(for: .seconds(Animation.playerQueueAnimationDuration + 0.1))
            if revealsContent { showsSpinner = false }
        }
    }

    func setUserScrolling(_ scrolling: Bool) {
        guard isUserScrolling != scrolling else { return }
        isUserScrolling = scrolling
    }

    /// Builds one more row at each end of the window, toward what's wanted around the current line —
    /// the rows coming up left for later. One at a time, so that no frame has more than a row to
    /// build. `true` once there's nothing left to add.
    private func growWindowAroundCurrent() -> Bool {
        guard case .synced(_, let layout) = phase else { return true }
        let wanted = layout.window(around: currentIndex)
        var grown = window
        if grown.start > wanted.start { grown.start -= 1 }
        if grown.end < wanted.end { grown.end += 1 }
        guard grown != window else { return true }
        window = grown
        return false
    }

    func setWindow(_ window: LyricsLayout.Window) {
        guard window != self.window else { return }
        self.window = window
    }

    func setBrowsing(_ browsing: Bool) {
        withAnimation(Self.changeAnimation) {
            isBrowsing = browsing
            if !browsing { layoutIndex = currentIndex }
        }
    }

    func requestScroll(to index: Int, duration: TimeInterval) {
        if case .synced(_, let layout) = phase { window = window.union(layout.window(around: index)) }
        scrollRequest = ScrollRequest(target: index, duration: duration, generation: scrollRequest.generation + 1)
    }

    // MARK: - Following the song

    /// Brings the lyrics in step with where the song is now. Idempotent, and cheap when nothing
    /// changes, so it can be called on every frame and on every event that might have moved the song.
    func follow() {
        follow(position: PlayerManager.shared.livePosition, now: Date())
    }

    private func follow(position: TimeInterval, now: Date) {
        // Writing what the views observe can run their pending `onChange` actions on the spot —
        // among them the one that calls this — in the middle of the change being made.
        guard !isFollowing else { return }
        isFollowing = true
        defer {
            isFollowing = false
            lastPosition = position
            lastDate = now
        }
        guard follows, case .synced(let timeline, _) = phase else { return }
        // The break stays current while a tap's dots shrink away; the timer moves on from there.
        guard tapHold == nil else { return }
        let previous = min(currentIndex, timeline.count - 1)
        let jumped = lastDate.map { last in
            let drift = position - lastPosition
            // Playing on moves the position by as much as time has passed; frames further apart
            // than a moment mean the song wasn't being followed meanwhile (paused, or the app away).
            return drift > min(now.timeIntervalSince(last), 0.5) + Self.seekThreshold || drift < -Self.seekThreshold
        } ?? false

        var index = timeline.index(at: position)
        let current = timeline.lines[previous]
        if current.isBreak, let next = timeline.nextStart(after: previous), index == previous || index == previous + 1 {
            // A break hands over when its own plan's scroll starts, which `index(at:)` doesn't know
            // for a plan that was squeezed, or for one with no dots.
            let lead = breakPlan?.index == previous ? (breakPlan?.timings?.scroll ?? Self.dotlessHandOverLead) : LyricsTimeline.scrollDuration
            index = position >= next - lead ? previous + 1 : previous
        }

        if index != previous {
            let scroll: ScrollRequest.Mode
            if isBrowsing {
                scroll = .none
            } else if !jumped, index == previous + 1 {
                let planned = breakPlan?.index == previous ? breakPlan?.timings?.scroll : nil
                scroll = .animated((current.isBreak ? planned : timeline.scrollDurations[index]) ?? LyricsTimeline.scrollDuration)
            } else if jumped, abs(index - previous) > Self.farJump {
                // Far from where it was (a seek) the lyrics jump, rather than run past all the
                // lines between.
                scroll = .jump
            } else {
                scroll = .animated(LyricsTimeline.scrollDuration)
            }
            if timeline.lines[index].isBreak {
                planBreak(at: index, position: position, timeline, restoring: false)
            }
            setCurrent(index, scroll: scroll)
        } else if jumped, current.isBreak {
            replanBreak(at: previous, position: position, timeline)
        }
        updateDotsEnding(position: position, timeline)
    }

    /// Decides, from what's left of the break at `index`, whether it draws dots and how they
    /// leave: with too little left for them to so much as shrink away (the lyrics were opened, or
    /// the song sought, to near its end) it draws none, rather than dots that show up just as the
    /// next line moves in over them.
    ///
    /// `restoring`: the lyrics were opened, or a restored song picked up, with the song in the
    /// middle of the break's ending — then the dots are where they would have been had they been
    /// showing all along, rather than squeezed into what's left (which is for a song sought to
    /// there). Their leaving is a function of the song's position, so it's as it was when the song
    /// was paused, between sessions too.
    private func planBreak(at index: Int, position: TimeInterval, _ timeline: LyricsTimeline, restoring: Bool) {
        tapEnding = nil
        guard let next = timeline.nextStart(after: index) else {
            breakPlan = BreakPlan(index: index, timings: nil)
            return
        }
        var timings = LyricsTimeline.breakTimings(available: next - position)
        if restoring,
           let full = LyricsTimeline.breakTimings(available: next - timeline.lines[index].start),
           position >= next - full.lead {
            timings = full
        }
        breakPlan = BreakPlan(index: index, timings: timings)
    }

    /// The song was sought within the break that is current, so what's left of it is worked out
    /// again — unless its dots had begun to leave and the seek keeps them leaving. A break that has
    /// dots keeps them, however little is left; one that has none gets them back only if the song
    /// was sought to where there's room again.
    private func replanBreak(at index: Int, position: TimeInterval, _ timeline: LyricsTimeline) {
        guard let next = timeline.nextStart(after: index), let plan = breakPlan, plan.index == index else {
            planBreak(at: index, position: position, timeline, restoring: false)
            return
        }
        if let timings = plan.timings, lastPosition >= next - timings.lead, position >= next - timings.lead - 0.5 {
            return
        }
        if let timings = LyricsTimeline.breakTimings(available: next - position) {
            breakPlan = BreakPlan(index: index, timings: timings)
        } else if plan.timings != nil {
            breakPlan = BreakPlan(index: index, timings: LyricsTimeline.hurriedTimings(available: next - position))
        }
    }

    private func updateDotsEnding(position: TimeInterval, _ timeline: LyricsTimeline) {
        let ending: Bool
        if tapHold != nil {
            ending = true
        } else if let plan = breakPlan, plan.index == currentIndex, let timings = plan.timings,
                  let next = timeline.nextStart(after: currentIndex) {
            ending = position >= next - timings.lead
        } else {
            ending = false
        }
        if dotsEnding != ending { dotsEnding = ending }
    }

    /// A tap on a line: the song is being sought to it (call this just before), and the lyrics
    /// follow. A break that's showing has its dots shrink away first, at once and from wherever the
    /// pulse has them, and then the lyrics move — the break's own hand-over, which would otherwise
    /// do that, plays out its dots' grow too.
    func tap(_ line: Int) {
        stopBrowsing(scrollBack: false)
        tapTask?.cancel()
        tapHold = nil
        guard case .synced(let timeline, _) = phase else { return }
        let index = min(currentIndex, timeline.count - 1)
        let position = PlayerManager.shared.livePosition
        guard timeline.lines[index].isBreak, breakPlan?.index == index, let timings = breakPlan?.timings,
              let next = timeline.nextStart(after: index), position < next - timings.lead
        else {
            // A break whose dots had begun to leave stays gone while its row fades out, though the
            // song is now sought to somewhere before it.
            tapEnding = timeline.lines[index].isBreak
                ? TapEnding(index: index, since: .distantPast, pulseTime: position)
                : nil
            setCurrent(line, scroll: isBrowsing ? .none : .animated(LyricsTimeline.scrollDuration))
            return
        }
        tapHold = line
        tapEnding = TapEnding(index: index, since: Date(), pulseTime: position)
        dotsEnding = true
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LyricsTimeline.breakExitDuration))
            // Not if another tap has taken over in the meantime.
            guard !Task.isCancelled, let self, self.tapHold == line else { return }
            self.tapHold = nil
            self.setCurrent(line, scroll: self.isBrowsing ? .none : .animated(LyricsTimeline.scrollDuration))
        }
    }

    // MARK: - Browsing

    /// The user's finger is on the lyrics, or they're coasting (`true`); they've stopped.
    func scrollPhase(isUser: Bool) {
        if isUser {
            browseTask?.cancel()
            guard !isBrowsing else { return }
            setBrowsing(true)
        } else if isBrowsing {
            // Once they've been left alone long enough, back to the current line.
            browseTask?.cancel()
            browseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.browsingTimeout))
                guard !Task.isCancelled else { return }
                self?.stopBrowsing(scrollBack: true)
            }
        }
    }

    private func stopBrowsing(scrollBack: Bool) {
        browseTask?.cancel()
        guard isBrowsing else { return }
        setBrowsing(false)
        if scrollBack { requestScroll(to: currentIndex, duration: LyricsTimeline.scrollDuration) }
    }
}

extension LyricsModel.ScrollRequest {
    enum Mode: Sendable {
        case none
        case jump
        case animated(TimeInterval)
    }
}
