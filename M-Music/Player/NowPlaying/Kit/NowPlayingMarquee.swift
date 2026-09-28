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
    /// When the current text started — the scroll's clock. Reset whenever `text` changes.
    @State private var startDate = Date()

    var body: some View {
        let metrics = NSString(string: text).size(withAttributes: [.font: font])
        let overflows = containerWidth > 0 && metrics.width > containerWidth
        let gap = metrics.height * 2
        let travel = metrics.width + gap
        let edge = overflows ? fade : 0

        TimelineView(.animation(paused: !(overflows && isActive))) { context in
            let offset = overflows ? scrollOffset(at: context.date, travel: travel) : 0
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
                            HStack(spacing: gap) {
                                Text(text)
                                if overflows { Text(text) }
                            }
                            .font(Font(font))
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: edge - offset)
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
        }
        .onChange(of: text) { startDate = Date() }
        .onChange(of: restartToken) { startDate = Date() }
    }

    /// 0 while pausing at the start of a loop, then growing at `speed` until one full copy of the
    /// text plus the gap has gone by — at which point the second copy sits exactly where the first
    /// started, so the loop is seamless.
    private func scrollOffset(at date: Date, travel: CGFloat) -> CGFloat {
        let cycle = startDelay + Double(travel / speed)
        let elapsed = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
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
