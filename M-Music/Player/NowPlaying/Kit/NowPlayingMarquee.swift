import SwiftUI

/// A single line of text that scrolls sideways, looping, when it's too wide for the space it's
/// given — the now-playing title/artist marquee, modeled on the `MarqueeText` package's look (two
/// copies of the text a couple of line-heights apart, 30 pt/s, soft fades at the edges) but built
/// to live inside the expanding/collapsing chrome, which the package view can't:
///
/// - **It's laid out like plain text.** The label is a normal, flexible-width view (a clear box the
///   height of one line, with the text in an overlay), so when an ancestor's size or position is
///   animated — expanding, collapsing, dragging the sheet — it follows along like any other view
///   instead of snapping to its final position or being left behind.
/// - **Its scroll is driven by the clock, not by an animation.** The package starts a
///   `repeatForever` animation once and never again, and SwiftUI drops that whenever the view sits
///   at opacity 0, so the title froze after a collapse/expand or a track change made while hidden.
///   Here the offset is a pure function of the time since the text last changed, recomputed every
///   frame by a `TimelineView` — nothing to start, stop, drop or restart, and it keeps scrolling
///   straight through any transition.
///
/// The clock starts afresh whenever the text changes and whenever the label starts to scroll — it
/// does that mid-animation too, as the container narrows past the text's width — and the frame in
/// which that happens is drawn at the start position, not at wherever the clock of the text before
/// (or of the label's last scroll) had got to: that showed as the text jumping sideways for a
/// moment and then back.
///
/// While `isActive` is false (the chrome is hidden) the timeline is paused, so an always-mounted
/// but invisible chrome costs no per-frame work.
struct NowPlayingMarquee: View {
    let text: String
    let font: UIFont
    var fade: CGFloat = 16
    /// Pause at the start of every loop, before scrolling begins.
    var startDelay: TimeInterval = 1.5
    /// Scroll speed, in points per second.
    var speed: CGFloat = 30
    var isActive = true
    /// Changing this restarts the scroll from the beginning (the start position, then the usual
    /// pause) — for when the label is about to be shown again.
    var restartToken = 0

    @State private var containerWidth: CGFloat = 0
    /// The scroll's clock. It only counts for the text and the scrolling state it was started for
    /// (see the type's doc comment); until it has been started for the current ones, the label
    /// sits at its start position.
    @State private var clock = ScrollClock()

    var body: some View {
        let metrics = Self.metrics(for: text, font: font)
        let overflows = containerWidth > 0 && metrics.width > containerWidth
        let clockKey = ScrollClock.Key(text: text, scrolls: overflows)
        let gap = metrics.height * 2
        let travel = metrics.width + gap
        let edge = overflows ? fade : 0

        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: metrics.height)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width.rounded() }) { width in
                if containerWidth != width { containerWidth = width }
            }
            .overlay(alignment: .leading) {
                // While scrolling, the visible window reaches `edge` further left than the
                // label's own bounds (a negative leading padding), and the text is pushed
                // right by the same amount — so at rest it starts exactly where plain text
                // would, and the left fade lives in the extra strip, always on, beginning
                // before the text's start position instead of eating into it.
                let label = Color.clear
                    .overlay(alignment: .leading) {
                        // Only this is drawn on every frame, and all that changes between
                        // frames is how far the text is moved: the text itself is an unchanged,
                        // `Equatable` view that isn't evaluated again. Redrawing everything above
                        // and around it every frame cost twice the CPU, which is why the scroll
                        // used to be held to 30 frames a second — and moved in steps of a point,
                        // visibly, on a display that runs at 60 or 120. It's drawn on every
                        // display frame.
                        //
                        // Moved by a transform rather than an `.offset`: an offset changes where
                        // the text is placed, and SwiftUI then built its glyphs' display list
                        // again on every frame; a transform moves the unchanged text as it is,
                        // at little over half the cost.
                        TimelineView(.animation(paused: !(overflows && isActive))) { context in
                            let offset = overflows && clock.key == clockKey
                                ? scrollOffset(at: context.date, since: clock.start, travel: travel)
                                : 0
                            MarqueeText(text: text, font: font, gap: gap, repeats: overflows)
                                .equatable()
                                .transformEffect(CGAffineTransform(translationX: edge - offset, y: 0))
                        }
                    }
                // Clipped and faded only when there's something to clip: text that fits is
                // left alone, since a clip/mask on it does nothing at rest and, while an
                // ancestor's layout is animating, can slice the text against its own frame.
                if overflows {
                    label
                        .clipped()
                        .mask(fadeMask(edge: edge))
                        .padding(.leading, -edge)
                } else {
                    label
                }
            }
        .onChange(of: clockKey, initial: true) { _, key in clock = ScrollClock(key: key, start: Date()) }
        .onChange(of: restartToken) { clock.start = Date() }
    }

    /// The text, twice (a gap apart) when it scrolls — a view of its own so that frames which only
    /// move it don't evaluate it again.
    private struct MarqueeText: View, Equatable {
        let text: String
        let font: UIFont
        let gap: CGFloat
        let repeats: Bool

        var body: some View {
            HStack(spacing: gap) {
                Text(text)
                if repeats { Text(text) }
            }
            .font(Font(font))
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// When the label's current scroll started, and for what.
    private struct ScrollClock {
        struct Key: Equatable {
            let text: String
            let scrolls: Bool
        }

        var key: Key?
        var start = Date()
    }

    private struct MetricsKey: Hashable {
        let text: String
        let fontName: String
        let pointSize: CGFloat
    }

    /// Measuring text is a UIKit/CoreText call, and `body` re-runs whenever the label's width or
    /// state changes — on most frames of the expand/collapse morph, for each of the four labels.
    /// A label's metrics only depend on its text and font, so they're measured once. Main-thread
    /// only, like `SongRow.artworkURLCache`.
    private static var metricsCache: [MetricsKey: CGSize] = [:]

    private static func metrics(for text: String, font: UIFont) -> CGSize {
        let key = MetricsKey(text: text, fontName: font.fontName, pointSize: font.pointSize)
        if let cached = metricsCache[key] { return cached }
        let size = NSString(string: text).size(withAttributes: [.font: font])
        if metricsCache.count >= 256 { metricsCache.removeAll(keepingCapacity: true) }
        metricsCache[key] = size
        return size
    }

    /// 0 while pausing at the start of a loop, then growing at `speed` until one full copy of the
    /// text plus the gap has gone by — at which point the second copy sits exactly where the first
    /// started, so the loop is seamless.
    private func scrollOffset(at date: Date, since start: Date, travel: CGFloat) -> CGFloat {
        let cycle = startDelay + Double(travel / speed)
        let elapsed = max(date.timeIntervalSince(start), 0).truncatingRemainder(dividingBy: cycle)
        return elapsed <= startDelay ? 0 : CGFloat(elapsed - startDelay) * speed
    }

    /// Soft edges, only while scrolling and constant: the left fade sits in the `edge`-wide strip
    /// before the text's start position, the right one in the last `edge` points.
    private func fadeMask(edge: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: edge)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: edge)
        }
    }
}
