import SwiftUI

/// The song's lyrics, shown in the expanded player in place of the big artwork — the lyrics
/// counterpart of `PlayerQueueList`, hosted by `RegularChrome` the same way (and so with the same
/// top and bottom fades). Plain lyrics are scrollable text; synced lyrics are lines that follow
/// the song.
///
/// These views hold no state of their own and observe nothing but `LyricsModel`: what's current,
/// when to scroll, what the dots do are all worked out by `LyricsConductor`, off the main actor.
struct PlayerLyricsView: View {
    /// Width of the screen this sits on — see `SyncedLyricsView`.
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
        switch model.phase {
        case .idle:
            Color.clear
        case .loading:
            ProgressView()
                .tint(Color.transparentWhite)
                .padding(.top, 48)
        case .synced(let timeline, let layout):
            // Replaced, not updated, when the song changes: the scroll position and the current
            // line belong to one song's lines.
            SyncedLyricsView(timeline: timeline, layout: layout, width: width, panelHeight: panelHeight)
                .id(timeline.identity)
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

/// Lyrics with timing: the sung lines, the current one white and slightly larger and at the top of
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
private struct SyncedLyricsView: View {
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
                    ForEach(segments(layoutIndex: layoutIndex, window: window)) { segment in
                        switch segment {
                        case .spacer(_, let height):
                            // Nothing to draw, but the room the lines it stands for take.
                            Color.clear.frame(height: height)
                        case .row(let line):
                            row(line, current: current, layoutIndex: layoutIndex, browsing: browsing)
                        }
                    }
                }
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
            }
            .scrollIndicators(.hidden)
            // The lines rest below the fade, which is taller here than the queue's, so the
            // previous line shows through it, softly, above the current one.
            .contentMargins(.top, Self.topFade, for: .scrollContent)
            // Room to scroll the last line all the way to the top.
            .contentMargins(.bottom, max(panelHeight, PlayerQueueList.FadeMask.bottomFade), for: .scrollContent)
            .mask { LyricsTopFade(height: Self.topFade) }
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
                switch phase {
                case .interacting, .decelerating:
                    LyricsConductor.shared.send(.scrollPhase(isUser: true))
                case .idle:
                    LyricsConductor.shared.send(.scrollPhase(isUser: false))
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
            // The conductor says when and where to scroll.
            .onChange(of: model.scrollRequest) { _, request in
                guard timeline.lines.indices.contains(request.target) else { return }
                if let duration = request.duration {
                    withAnimation(.smooth(duration: duration)) { proxy.scrollTo(request.target, anchor: .top) }
                } else {
                    proxy.scrollTo(request.target, anchor: .top)
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
            // Tapping a line plays from it. The whole row takes the tap, not just the glyphs; a
            // drag on it still scrolls. The conductor is told first, so it knows a tap is what
            // moved the position.
            .contentShape(.rect)
            .onTapGesture {
                LyricsConductor.shared.send(.tap(line.id, time: line.start))
                PlayerManager.shared.seek(to: line.start)
            }
        } else {
            let next = timeline.nextStart(after: line.id)
            // The dots fill up by the time they start to leave.
            LyricBreakDots(
                start: line.start,
                end: next.map { $0 - (LyricsTimeline.breakTimings(available: $0 - line.start)?.lead ?? 0) },
                ending: model.breakEnding?.index == line.id ? model.breakEnding : nil
            )
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
/// The fade is an `.opacity` on the whole line, not a translucent text colour: animating a text's
/// own colour made SwiftUI re-rasterize its glyphs on the CPU every frame, which was most of what
/// the lyrics cost; a layer's opacity is just composited.
private struct LyricLineView: View, Equatable {
    let text: String
    /// How many sung lines away from the current one this is (capped); 0 for the current line.
    let distance: Int
    /// Whether the lines further from the current one are blurred; off while the user scrolls.
    let isBlurred: Bool
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
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
/// Everything is a function of the `TimelineView`'s date and the model's clock anchor, so there's
/// nothing to observe or keep: the pulse and the fill are drawn at ~20 fps (they're slow), and only
/// the grow and shrink at the full rate.
private struct LyricBreakDots: View {
    let start: TimeInterval
    /// When the dots should be full; `nil` for a break at the very end, which fill over the rest
    /// of the song.
    let end: TimeInterval?
    /// How the dots are leaving, once the break is over; `nil` while it's still going.
    let ending: BreakEnding?

    private let model = LyricsModel.shared

    private static let pulseMaxScale: CGFloat = 1.18
    /// One full swell and relaxation of the pulse.
    private static let pulsePeriod: TimeInterval = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: ending == nil ? 1.0 / 20 : nil)) { context in
            let date = context.date
            let clock = model.clock
            // A break at the end runs for as long as the song has left; guard against a missing or
            // backwards duration.
            let finish = max(end ?? clock.duration, start + 1)
            let fraction = min(max((clock.estimate(at: date) - start) / (finish - start), 0), 1)
            let (scale, opacity) = scaleAndOpacity(at: date)
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(max(fraction * 3 - Double(index), 0), 1)
                    Circle()
                        .fill(Color.white.opacity(0.28 + 0.72 * fill))
                        .frame(width: 11, height: 11)
                }
            }
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
        // The pulse starts when the break does, so the dots come in at their smallest.
        let appearedAt = model.currentSince
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
        // Shrinks from the largest size, which the grow has just reached — or, with no grow, from
        // wherever the pulse had the dots.
        let from = grow > 0 ? Self.pulseMaxScale : pulseScale(after: ending.since.timeIntervalSince(appearedAt))
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
