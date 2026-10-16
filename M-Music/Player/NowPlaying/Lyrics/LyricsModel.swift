import SwiftUI
import Observation

/// What the lyrics views draw, and nothing else: all the timing and state-keeping is done by
/// `LyricsConductor`, off the main actor, which writes here only when something on screen
/// actually changes — a line becomes current, a break's dots start to leave, the user starts or
/// stops browsing. The views just read it, so none of them needs state of its own.
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

    /// The song's position as of the last update, which the dots carry forward on their own —
    /// they draw it at the display's rate, which the 2 Hz updates can't.
    ///
    /// A correction doesn't make the clock jump: it's eased in, the clock running a little slower
    /// or faster than the song for as long as it takes (`rate` for `span` seconds), so a position
    /// that comes in behind or ahead of where the clock had it never moves what's drawn backwards
    /// or in a hop.
    struct ClockAnchor: Equatable, Sendable {
        var time: TimeInterval = 0
        var wall = Date()
        var isPlaying = false
        var duration: TimeInterval = 0
        /// How fast the clock runs for the first `span` seconds after `wall`; 1 afterwards.
        var rate: Double = 1
        var span: TimeInterval = 0

        /// A little over the updates' interval, to allow for one that's a bit late: anything
        /// longer means none are coming (a stall), and the position stays where the last left it.
        static let maxExtrapolation: TimeInterval = 0.75
        /// How far from 1 the clock's rate goes to take in a correction.
        static let maxSlew = 0.5
        /// A correction of this much or more is a seek, and is followed at once.
        static let snapThreshold: TimeInterval = 1.0

        func estimate(at date: Date) -> TimeInterval {
            guard isPlaying else { return time }
            let elapsed = min(max(date.timeIntervalSince(wall), 0), Self.maxExtrapolation)
            let eased = min(elapsed, span)
            return time + eased * rate + (elapsed - eased)
        }
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
    /// When the current line became current.
    private(set) var currentSince = Date()
    private(set) var breakEnding: BreakEnding?
    /// The break that draws no dots: when it became current there was too little of it left for
    /// them to even shrink away, so they'd only have shown up as the next line moved in. It stays
    /// set until another break becomes current, so that the row fading out doesn't bring them back.
    private(set) var dotlessBreak: Int?
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
    private(set) var clock = ClockAnchor()

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
            breakEnding = nil
            dotlessBreak = nil
            isBrowsing = false
        }
    }

    /// Shows synced lyrics, positioned at `index` — in one step, so the lines never show with a
    /// previous song's current line.
    func showSynced(_ timeline: LyricsTimeline, _ layout: LyricsLayout, at index: Int) {
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
        currentSince = Date()
        breakEnding = nil
        scrollRequest = ScrollRequest(target: index, duration: nil, generation: scrollRequest.generation + 1)
    }

    func setCurrent(_ index: Int, scroll: ScrollRequest.Mode) {
        let now = Date()
        withAnimation(Self.changeAnimation) {
            currentIndex = index
            if !isBrowsing { layoutIndex = index }
            currentSince = now
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
    func growWindowAroundCurrent() -> Bool {
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

    func setDotlessBreak(_ index: Int?) {
        guard dotlessBreak != index else { return }
        dotlessBreak = index
    }

    func setBreakEnding(_ ending: BreakEnding?) {
        breakEnding = ending
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

    func setClock(_ clock: ClockAnchor) {
        self.clock = clock
    }
}

extension LyricsModel.ScrollRequest {
    enum Mode: Sendable {
        case none
        case jump
        case animated(TimeInterval)
    }
}
