import SwiftUI

/// The song's lyrics, shown in the expanded player in place of the big artwork — the lyrics
/// counterpart of `PlayerQueueList`, hosted by `RegularChrome` the same way (and so with the same
/// top and bottom fades). Plain lyrics are scrollable text; synced lyrics are lines that follow
/// the song.
///
/// These views hold next to no state of their own and observe `LyricsModel`: what's current and
/// when to scroll it works out from the player's position, on every frame the song plays (see
/// `LyricsFollower`); the dots draw from that position themselves.
struct PlayerLyricsView: View {
    /// Width of the screen this sits on — see `LyricsScrollView`.
    var width: CGFloat
    /// The room the panel has, so synced lyrics can scroll their last line up to the top.
    var panelHeight: CGFloat

    private let model = LyricsModel.shared

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            // The conductor works only while the panel is up.
            .onAppear { LyricsConductor.shared.send(.activate(true, width: width)) }
            .onDisappear { LyricsConductor.shared.send(.activate(false, width: width)) }
    }

    @ViewBuilder
    private var content: some View {
        if case .idle = model.phase {
            Color.clear
        } else {
            scroll
        }
    }

    /// The lyrics' scroll view, whatever they turn out to be — synced lines, plain text or the
    /// word that there are none — which is there from when they start to load (empty, with a
    /// spinner over it), and has them put in it when they arrive. Made only then, it would miss
    /// the panel's move up and fade in, which began before it existed (a scroll view made in the
    /// middle of an animation is simply put at its end state), and the lyrics would just appear,
    /// uncovered by the artwork shrinking away. A different song's lyrics replace it, as the scroll
    /// position and the current line belong to one song's lines.
    @ViewBuilder
    private var scroll: some View {
        let (kind, lyrics) = scrollContents
        ZStack(alignment: .top) {
            LyricsScrollView(
                kind: kind,
                timeline: lyrics?.0 ?? Placeholder.timeline,
                layout: lyrics?.1 ?? Placeholder.layout,
                width: width,
                panelHeight: panelHeight
            )
            .id(model.session)
            if model.showsSpinner {
                ProgressView()
                    .tint(Color.transparentWhite)
                    .padding(.top, 48)
                    .opacity(model.revealsContent ? 0 : 1)
            }
        }
    }

    /// What the scroll view holds, from the phase the lyrics are in.
    private var scrollContents: (LyricsScrollView.Kind, (LyricsTimeline, LyricsLayout)?) {
        switch model.phase {
        case .synced(let timeline, let layout): (.lines, (timeline, layout))
        case .plain(let text): (.plain(text), nil)
        case .unavailable: (.unavailable, nil)
        case .idle, .loading: (.loading, nil)
        }
    }

    /// What the scroll view is given to hold while there's nothing to show in it.
    private enum Placeholder {
        static let timeline = LyricsTimeline(timed: [(0, "…")])!
        static let layout = LyricsLayout(timeline: timeline, textWidth: 300)
    }
}

/// The lyrics' scroll view. Synced lyrics (the `.lines` kind) are the sung lines, the current one white and slightly larger and at the top of
/// the view, the others fainter and blurrier the further they are from it. The view scrolls itself
/// as the song plays, and tapping a line seeks to it; while the user scrolls them it stops, and
/// every line but the current one looks alike, until they've been left alone for a few seconds. An
/// empty line is an instrumental break, drawn as three dots — but only while it is the current
/// line: it appears when the break begins and is gone again when the next line comes, so scrolling
/// through the lyrics never shows one.
///
/// Every line has a slot of a height measured in advance (`LyricsLayout`), holding a real row if
/// it's near what's on screen and an empty spacer otherwise, so the content's height is exact and
/// constant however far the user scrolls.
private struct LyricsScrollView: View {
    /// What the view holds. Plain lyrics are text, scrolling, with the same fades as the queue's
    /// list; "Lyrics not available" sits at the top of the same kind of view. While they load
    /// (`.loading`) it's empty.
    enum Kind {
        case loading
        case lines
        case plain(String)
        case unavailable

        /// Whether it's laid out like plain text, not like synced lines.
        var isText: Bool {
            switch self {
            case .plain, .unavailable: true
            case .loading, .lines: false
            }
        }
    }

    let kind: Kind
    let timeline: LyricsTimeline
    let layout: LyricsLayout
    let width: CGFloat
    let panelHeight: CGFloat

    private let model = LyricsModel.shared

    /// The height of the fade at the top of the view.
    private static let topFade: CGFloat = 56

    /// Less tall than this (what's showing of it, margins included), the view is still growing into
    /// its panel.
    private static let minimumHeight: CGFloat = 100

    /// How much more room the current line has above and below it than lines have between each
    /// other, so it stands a little apart from the previous and the following line.
    private static let currentLineExtraSpacing: CGFloat = 8

    /// Lines further than this from the current one all look the same (the fade bottoms out and the
    /// blur tops out well before), so their views never have to change as it moves.
    private static let maxStyledDistance = 6


    var body: some View {
        let current = min(model.currentIndex, timeline.count - 1)
        let layoutIndex = min(model.layoutIndex, timeline.count - 1)
        let browsing = model.isBrowsing
        let window = model.window
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch kind {
                    case .plain(let text):
                        Text(text)
                            .font(.system(size: 20, weight: .semibold))
                            .lineSpacing(5)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .unavailable:
                        Text("Lyrics not available")
                            .font(.body)
                            .foregroundStyle(Color.transparentWhite)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    case .loading, .lines:
                        ForEach(segments(layoutIndex: layoutIndex, window: window)) { segment in
                            switch segment {
                            case .spacer(_, let height):
                                // Nothing to draw, but the room the lines it stands for take.
                                Color.clear.frame(height: height)
                            case .row(let line):
                                row(line, current: current, layoutIndex: layoutIndex, browsing: browsing)
                            }
                        }
                        // Room to scroll the last line all the way to the top. Content, not a scroll
                        // margin: a bottom margin this tall, alongside the top one, made the scroll
                        // view itself that much taller than the room it was given, over the scrubber
                        // below — which then was hard to get a finger onto.
                        Color.clear.frame(height: max(panelHeight, PlayerQueueList.FadeMask.bottomFade))
                    }
                }
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
                .opacity(model.revealsContent ? 1 : 0)
            }
            .scrollIndicators(.hidden)
            .background {
                if case .lines = kind { LyricsFollower() }
            }
            // The lines rest below the fade, which is taller here than the queue's, so the
            // previous line shows through it, softly, above the current one. Text has the queue's.
            .contentMargins(.top, kind.isText ? PlayerQueueList.FadeMask.topFade : Self.topFade, for: .scrollContent)
            .contentMargins(.bottom, kind.isText ? PlayerQueueList.FadeMask.bottomFade : 0, for: .scrollContent)
            .mask {
                if kind.isText {
                    PlayerQueueList.TopFade()
                } else {
                    LyricsTopFade(height: Self.topFade)
                }
            }
            // Which rows to build follows what's on screen as the user scrolls — once there's a screen
            // to speak of: the view is mounted while its panel is still growing out of nothing.
            .onScrollGeometryChange(for: LyricsLayout.Window?.self) { [layout] geometry in
                geometry.visibleRect.height > Self.minimumHeight
                    ? layout.window(top: geometry.visibleRect.minY, bottom: geometry.visibleRect.maxY)
                    : nil
            } action: { _, window in
                // Only while the user's finger is moving them. The lyrics scrolling themselves
                // build the rows they need before they start (see `LyricsModel`) — and rows
                // coming and going under a scroll animation made it lurch.
                if let window, model.isUserScrolling { model.setWindow(window) }
            }
            // To wherever the song already is, as soon as there's room to scroll in: a jump, not a
            // glide from the top.
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.height > Self.minimumHeight } action: { _, isSized in
                // A turn later: this runs inside the first layout, before the lines are in place.
                if isSized { DispatchQueue.main.async { proxy.scrollTo(model.currentIndex, anchor: .top) } }
            }
            // The user's own scrolling, as opposed to this view's (`.animating`) — not `.tracking`,
            // which is a finger that has touched the lyrics but hasn't moved them (yet): a tap on a
            // line starts out like that.
            .onScrollPhaseChange { _, phase, context in
                guard case .lines = kind else { return }
                switch phase {
                case .interacting, .decelerating:
                    model.scrollPhase(isUser: true)
                case .idle:
                    model.scrollPhase(isUser: false)
                case .tracking, .animating:
                    break
                @unknown default:
                    break
                }
                let wasUserScrolling = model.isUserScrolling
                model.setUserScrolling(phase == .interacting || phase == .decelerating)
                // When the user's scrolling stops, the window settles on where it stopped. Not when
                // this view's own scroll does: swapping rows far above for a spacer then made the
                // scroll view scroll on, past the line it had just arrived at.
                if phase == .idle, wasUserScrolling {
                    model.setWindow(layout.window(top: context.geometry.visibleRect.minY, bottom: context.geometry.visibleRect.maxY))
                }
            }
            // The model says when and where to scroll.
            .onChange(of: model.scrollRequest) { _, request in
                guard timeline.lines.indices.contains(request.target) else { return }
                if let duration = request.duration {
                    withAnimation(.smooth(duration: duration)) { proxy.scrollTo(request.target, anchor: .top) }
                } else if request.settles {
                    // A seek far from where the lyrics were: the rows around the target were
                    // swapped in for spacers just now, and aren't laid out until a moment later.
                    // Scrolling to a line then lands where the layout before the swap had it — with
                    // lines of different heights, far from the line (a jump back to the start from a
                    // break scrolled on to a line some way down). So a moment later, and once more
                    // in case that was early too.
                    for delay in [0.05, 0.2] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard model.scrollRequest == request else { return }
                            proxy.scrollTo(request.target, anchor: .top)
                        }
                    }
                } else {
                    // A turn later: the lyrics may have just been put in the view (see `synced`), and
                    // their lines aren't in place yet.
                    DispatchQueue.main.async { proxy.scrollTo(request.target, anchor: .top) }
                }
            }
        }
    }

    /// What the stack is made of: a real row for each line near what's on screen — and for the
    /// current line and its neighbours, which the layout and the scrolling need — and, for each run
    /// of the others, one spacer of the height they add up to.
    private enum Segment: Identifiable {
        case spacer(start: Int, height: CGFloat)
        case row(SyncedLyricLine)

        var id: Int {
            switch self {
            case .spacer(let start, _): -1 - start
            case .row(let line): line.id
            }
        }
    }

    private func segments(layoutIndex: Int, window: LyricsLayout.Window) -> [Segment] {
        var result: [Segment] = []
        var pending: CGFloat = 0
        var pendingStart = 0
        for line in timeline.lines {
            if line.isBreak ? line.id == layoutIndex : (window.contains(line.id) || abs(line.id - layoutIndex) <= 1) {
                if pending > 0 {
                    result.append(.spacer(start: pendingStart, height: pending))
                    pending = 0
                }
                result.append(.row(line))
            } else if !line.isBreak {
                if pending == 0 { pendingStart = line.id }
                pending += layout.textHeights[line.id] + LyricsLayout.rowSpacing
            }
        }
        if pending > 0 { result.append(.spacer(start: pendingStart, height: pending)) }
        return result
    }

    @ViewBuilder
    private func row(_ line: SyncedLyricLine, current: Int, layoutIndex: Int, browsing: Bool) -> some View {
        if !line.isBreak {
            let distance = timeline.distance(of: line.id, from: current)
            LyricLineView(
                text: line.text,
                width: min(layout.textWidth, LyricsLayout.textWidth(forViewWidth: width)),
                // Browsing, every line but the current one looks like the next, and none is
                // blurred.
                distance: browsing ? min(distance, 1) : min(distance, Self.maxStyledDistance),
                isBlurred: !browsing,
                scale: LyricsLayout.currentScale
            )
            .equatable()
            // The height it was measured at, so the slot is exactly the size the layout made it.
            .frame(height: layout.textHeights[line.id], alignment: .top)
            .id(line.id)
            // The extra room is outside the `id`, so that scrolling to the line puts its text at
            // the top, not the gap above it.
            .padding(.vertical, line.id == layoutIndex ? Self.currentLineExtraSpacing : 0)
            .padding(.bottom, LyricsLayout.rowSpacing)
            .padding(.trailing, unusedWidthWhenScaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Tapping a line plays from it. The whole row takes the tap, not just the glyphs; a
            // drag on it still scrolls. The model is told first, so it knows a tap is what moved
            // the position.
            .contentShape(.rect)
            .onTapGesture {
                model.tap(line.id)
                PlayerManager.shared.seek(to: line.start)
            }
        } else {
            let plan = model.breakPlan?.index == line.id ? model.breakPlan : nil
            Group {
                if let plan, plan.timings == nil {
                    // Their room, without them: the line after is about to move in.
                    Color.clear.frame(maxWidth: .infinity, minHeight: LyricBreakDots.height)
                } else {
                    LyricBreakDots(
                        start: line.start,
                        next: timeline.nextStart(after: line.id),
                        index: line.id,
                        timings: plan?.timings
                    )
                }
            }
            .id(line.id)
            .padding(.vertical, Self.currentLineExtraSpacing)
            .padding(.bottom, LyricsLayout.rowSpacing)
            .transition(.opacity)
        }
    }

    private var unusedWidthWhenScaled: CGFloat {
        (width - NowPlayingLayout.cardPaddings * 2) * (1 - 1 / LyricsLayout.currentScale)
    }
}

/// One sung line of synced lyrics. It's `Equatable` and its inputs are capped, so that a change of
/// the current line only touches the few lines near it.
///
/// The text is given the width it was measured in (`LyricsLayout.textWidth`) outright, rather than
/// whatever its row is offered: the width a row is offered comes out a fraction of a point
/// different (a third of a point, or two thirds) from one row, and one scroll position, to the
/// next, and a line that fills its slot nearly to the edge went from two lines to three and back
/// as it scrolled.
///
/// Never more than the view has room for, though: the placeholder shown while lyrics load is
/// measured at a width of its own, and a row wider than its view made the content wider than the
/// view and centered on it — everything in the player's lower half jumped sideways while it showed.
///
/// The fade is an `.opacity` on the whole line, not a translucent text colour: animating a text's
/// own colour made SwiftUI re-rasterize its glyphs on the CPU every frame, which was most of what
/// the lyrics cost; a layer's opacity is just composited.
private struct LyricLineView: View, Equatable {
    let text: String
    let width: CGFloat
    /// How many sung lines away from the current one this is (capped); 0 for the current line.
    let distance: Int
    /// Whether the lines further from the current one are blurred; off while the user scrolls.
    let isBlurred: Bool
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: width, alignment: .leading)
            .scaleEffect(distance == 0 ? scale : 1, anchor: .leading)
            .blur(radius: isBlurred ? Self.blur(forDistance: distance) : 0)
            .opacity(distance == 0 ? 1 : Self.opacity(forDistance: distance))
    }

    /// Fainter with distance from the current line, down to a floor that keeps far lines legible.
    private static func opacity(forDistance distance: Int) -> Double {
        max(0.14, 0.45 - 0.09 * Double(distance - 1))
    }

    private static func blur(forDistance distance: Int) -> CGFloat {
        CGFloat(min(distance, 5)) * 1.1
    }
}

/// An instrumental break: three dots that fill with white, one after another, over the break's
/// length, and slowly pulse around the middle one. When the break ends they first grow, smoothly,
/// from wherever the pulse has them to its largest size, and then shrink away to nothing as they
/// fade out.
///
/// Everything is a function of the song's position — asked of the player on every frame the song
/// plays — and of the plan made for the break (`LyricsModel.BreakPlan`), so there's nothing to
/// keep: the dots stop when the song is paused, carry on from exactly where they were when it
/// resumes, and are as they were when a restored song is opened again. The pulse and the fill are
/// drawn at ~20 fps (they're slow), and only the grow and shrink at the full rate.
private struct LyricBreakDots: View {
    let start: TimeInterval
    /// When the line after the break starts.
    let next: TimeInterval?
    /// The break's line.
    let index: Int
    /// How they leave, as planned; `nil` if there's no plan for this break (it's not the current
    /// one), when it's the full sequence.
    let timings: BreakTimings?

    private let model = LyricsModel.shared
    private let player = PlayerManager.shared
    /// Its changes — a seek landing while paused — redraw the dots when no frames do.
    @ObservedObject private var playback = PlaybackProgress.shared
    @State private var advancing = false

    private static let pulseMaxScale: CGFloat = 1.18
    /// One full swell and relaxation of the pulse.
    private static let pulsePeriod: TimeInterval = 3.2

    var body: some View {
        let tapEnding = model.tapEnding?.index == index ? model.tapEnding : nil
        let schedule = AnimationTimelineSchedule(
            minimumInterval: model.dotsEnding ? nil : 1.0 / 20,
            paused: !advancing && tapEnding == nil
        )
        TimelineView(schedule) { context in
            let position = player.livePosition
            // The dots fill up by the time they start to leave.
            let full = next.flatMap { LyricsTimeline.breakTimings(available: $0 - start) }
            let finish = max((next ?? start) - (full?.lead ?? 0), start + 1)
            let fraction = min(max((position - start) / (finish - start), 0), 1)
            let (scale, opacity) = scaleAndOpacity(
                at: context.date, position: position, timings: timings ?? full, tapEnding: tapEnding
            )
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { dot in
                    let fill = min(max(fraction * 3 - Double(dot), 0), 1)
                    Circle()
                        .fill(Color.white.opacity(0.28 + 0.72 * fill))
                        .frame(width: 11, height: 11)
                }
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .onReceive(player.isAdvancingPublisher) { advancing = $0 }
    }

    /// The room the dots take.
    static let height: CGFloat = 34

    private func pulseScale(after elapsed: TimeInterval) -> CGFloat {
        let swell = (1 - cos(2 * .pi * max(elapsed, 0) / Self.pulsePeriod)) / 2
        return 1 + (Self.pulseMaxScale - 1) * CGFloat(swell)
    }

    private func scaleAndOpacity(
        at date: Date, position: TimeInterval, timings: BreakTimings?, tapEnding: LyricsModel.TapEnding?
    ) -> (CGFloat, Double) {
        // The pulse starts when the break does, so the dots come in at their smallest.
        let elapsed: TimeInterval
        let leaving: BreakTimings
        let pulseTime: TimeInterval
        if let tapEnding {
            // Sent away by a tap, they leave in their own time, playing or not.
            elapsed = max(date.timeIntervalSince(tapEnding.since), 0)
            leaving = BreakTimings(grow: 0, exit: LyricsTimeline.breakExitDuration, scroll: 0)
            pulseTime = tapEnding.pulseTime
        } else if let timings, let next, position >= next - timings.lead {
            // Leaving, they follow the song: they begin when it gets within `lead` of the next
            // line, and stop when it does.
            pulseTime = next - timings.lead
            elapsed = position - pulseTime
            leaving = timings
        } else {
            return (pulseScale(after: position - start), 1)
        }
        let grow = leaving.grow
        let leavingFrom = pulseScale(after: pulseTime - start)
        if elapsed < grow {
            // Eased at both ends, from the pulse's size at the moment the break ended.
            let progress = elapsed / grow
            let eased = progress * progress * (3 - 2 * progress)
            return (leavingFrom + (Self.pulseMaxScale - leavingFrom) * CGFloat(eased), 1)
        }
        let progress = min((elapsed - grow) / leaving.exit, 1)
        let eased = progress * progress
        // Shrinks from the largest size, which the grow has just reached — or, with no grow, from
        // wherever the pulse had the dots.
        let from = grow > 0 ? Self.pulseMaxScale : leavingFrom
        return (from + (0.01 - from) * CGFloat(eased), 1 - eased)
    }
}

/// `PlayerQueueList.TopFade`, at a height of its own: fades out the top `height` points of what it
/// masks.
private struct LyricsTopFade: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
            Rectangle()
        }
    }
}

/// Keeps the synced lyrics in step with the song: while it plays, on every frame of a
/// `TimelineView`, and otherwise whenever something might have moved it (a pause or a resume, a
/// seek landing), it has `LyricsModel` follow the position the player reports (`livePosition`). It
/// draws nothing.
private struct LyricsFollower: View {
    private let model = LyricsModel.shared
    /// Observed for its changes only — a seek landing, or the exact position published at a pause.
    @ObservedObject private var playback = PlaybackProgress.shared
    /// Observed, for the one thing: the player being up. Docked, nothing shows the lyrics.
    private let presentation = PlayerPresentation.shared
    /// Whether the song is advancing (see `PlayerManager.isAdvancingPublisher`).
    @State private var advancing = false

    var body: some View {
        TimelineView(.animation(paused: !(advancing && !presentation.accessoryVisible))) { context in
            Color.clear
                .onChange(of: context.date) { model.follow() }
        }
        .allowsHitTesting(false)
        .onAppear { model.follow() }
        .onChange(of: playback.currentTime) { model.follow() }
        .onReceive(PlayerManager.shared.isAdvancingPublisher) {
            advancing = $0
            // A turn later: the publisher speaks as the player's flags are about to change (a
            // seek starting hasn't yet made the position what it's being sought to), and the
            // position read then is the one the song is leaving.
            DispatchQueue.main.async { model.follow() }
        }
    }
}
