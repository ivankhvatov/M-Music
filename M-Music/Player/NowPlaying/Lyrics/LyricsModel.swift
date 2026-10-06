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
        case synced(LyricsTimeline)
        case plain(String)
        case unavailable
    }

    /// A request for the synced lyrics to scroll somewhere; `generation` makes two requests for the
    /// same line distinct, so each is acted on.
    struct ScrollRequest: Equatable {
        var target = 0
        /// How long the scroll takes; `nil` for a jump.
        var duration: TimeInterval?
        var generation = 0
    }

    /// The song's position as of the last update, which the dots carry forward on their own —
    /// they draw it at the display's rate, which the 2 Hz updates can't.
    struct ClockAnchor: Equatable, Sendable {
        var time: TimeInterval = 0
        var wall = Date()
        var isPlaying = false
        var duration: TimeInterval = 0

        /// A little over the updates' interval, to allow for one that's a bit late: anything
        /// longer means none are coming (a stall), and the position stays where the last left it.
        static let maxExtrapolation: TimeInterval = 0.75

        func estimate(at date: Date) -> TimeInterval {
            guard isPlaying else { return time }
            return time + min(max(date.timeIntervalSince(wall), 0), Self.maxExtrapolation)
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var currentIndex = 0
    /// When the current line became current.
    private(set) var currentSince = Date()
    private(set) var breakEnding: BreakEnding?
    /// The user is looking around the lyrics: every line but the current one looks alike.
    private(set) var isBrowsing = false
    private(set) var scrollRequest = ScrollRequest()
    private(set) var clock = ClockAnchor()

    /// Everything the views animate on a change of the current line or of browsing — line fades,
    /// the current line's extra room, a break's row appearing and going — rides this one
    /// animation, so only the rows that actually change animate.
    private static let changeAnimation = Animation.smooth(duration: 0.5)

    func setPhase(_ phase: Phase) {
        self.phase = phase
        if case .synced = phase {} else {
            currentIndex = 0
            breakEnding = nil
            isBrowsing = false
        }
    }

    /// Shows synced lyrics, positioned at `index` — in one step, so the lines never show with a
    /// previous song's current line.
    func showSynced(_ timeline: LyricsTimeline, at index: Int) {
        phase = .synced(timeline)
        currentIndex = index
        currentSince = Date()
        breakEnding = nil
        scrollRequest = ScrollRequest(target: index, duration: nil, generation: scrollRequest.generation + 1)
    }

    func setCurrent(_ index: Int, scroll: ScrollRequest.Mode) {
        let now = Date()
        withAnimation(Self.changeAnimation) {
            currentIndex = index
            currentSince = now
        }
        switch scroll {
        case .none:
            break
        case .jump:
            scrollRequest = ScrollRequest(target: index, duration: nil, generation: scrollRequest.generation + 1)
        case .animated(let duration):
            scrollRequest = ScrollRequest(target: index, duration: duration, generation: scrollRequest.generation + 1)
        }
    }

    func setBreakEnding(_ ending: BreakEnding?) {
        breakEnding = ending
    }

    func setBrowsing(_ browsing: Bool) {
        withAnimation(Self.changeAnimation) { isBrowsing = browsing }
    }

    func requestScroll(to index: Int, duration: TimeInterval) {
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
