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
/// - **Its scroll is driven by the clock, and moved by Core Animation.** The package starts a
///   `repeatForever` animation once and never again, and SwiftUI drops that whenever the view sits
///   at opacity 0, so the title froze after a collapse/expand or a track change made while hidden.
///   Here the position is a pure function of the time since the text last changed: the animation
///   that moves the text is made to agree with that clock, and made again whenever something may
///   have taken it away (the view leaving the window, the app the screen). The text is drawn once
///   and the system slides it, so a scroll costs the app nothing from frame to frame — drawing it
///   afresh for each one took more of the CPU, and of the battery, than anything else did while a
///   song played with the player docked.
///
/// The clock starts afresh whenever the text changes and whenever the label starts to scroll — it
/// does that mid-animation too, as the container narrows past the text's width — and the frame in
/// which that happens is drawn at the start position, not at wherever the clock of the text before
/// (or of the label's last scroll) had got to: that showed as the text jumping sideways for a
/// moment and then back.
///
/// While `isActive` is false (the chrome is hidden) the text is held where it is, so an
/// always-mounted but invisible chrome has nothing moving in it.
struct NowPlayingMarquee: View {
    let text: String
    let font: UIFont
    /// The color of the text while it scrolls. It has to be the one the surrounding
    /// `foregroundStyle` gives the text at rest, which UIKit knows nothing of.
    var color: UIColor = .label
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
        let edge = overflows ? fade : 0

        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: metrics.height)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width.rounded() }) { width in
                if containerWidth != width { containerWidth = width }
            }
            .overlay(alignment: .leading) {
                if overflows {
                    // The visible window reaches `edge` further left than the label's own bounds
                    // (a negative leading padding), and the text starts that far in — so at rest
                    // it is exactly where plain text would be, and the left fade lives in the
                    // extra strip, always on, beginning before the text's start position instead
                    // of eating into it.
                    ScrollingText(
                        text: text, font: font, color: color, textWidth: metrics.width, gap: gap,
                        edge: edge, speed: speed, startDelay: startDelay,
                        start: clock.key == clockKey ? clock.start : nil, isActive: isActive
                    )
                    .padding(.leading, -edge)
                } else {
                    // Text that fits is left alone: a clip or mask on it does nothing at rest
                    // and, while an ancestor's layout is animating, can slice the text against
                    // its own frame.
                    Color.clear
                        .overlay(alignment: .leading) {
                            Text(text)
                                .font(Font(font))
                                .lineLimit(1)
                                .fixedSize()
                        }
                }
            }
        .onChange(of: clockKey, initial: true) { _, key in clock = ScrollClock(key: key, start: Date()) }
        .onChange(of: restartToken) { clock.start = Date() }
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
}

/// The label while it scrolls: the text twice, a gap apart, behind soft edges.
private struct ScrollingText: UIViewRepresentable, Equatable {
    let text: String
    let font: UIFont
    let color: UIColor
    let textWidth: CGFloat
    let gap: CGFloat
    /// The width of the soft edges. The text starts that far in.
    let edge: CGFloat
    let speed: CGFloat
    let startDelay: TimeInterval
    /// When the scroll's clock started; `nil` until it has, and the text sits at its start.
    let start: Date?
    let isActive: Bool

    /// One full copy of the text and the gap: after it the second copy is exactly where the first
    /// started, so the loop is seamless.
    var travel: CGFloat { textWidth + gap }

    func makeUIView(context: Context) -> ScrollingTextView { ScrollingTextView() }

    func updateUIView(_ view: ScrollingTextView, context: Context) {
        view.show(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ScrollingTextView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class ScrollingTextView: UIView {
    private static let animationKey = "marquee"
    private let strip = UIView()
    private let first = UILabel()
    private let second = UILabel()
    private let fades = CAGradientLayer()
    private var shown: ScrollingText?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        second.isAccessibilityElement = false
        for label in [first, second] {
            label.lineBreakMode = .byClipping
            strip.addSubview(label)
        }
        addSubview(strip)
        fades.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        fades.startPoint = CGPoint(x: 0, y: 0.5)
        fades.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fades
        // Core Animation drops animations while the app is away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(animate), name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func show(_ label: ScrollingText) {
        guard label != shown else { return }
        shown = label
        for view in [first, second] {
            view.text = label.text
            view.font = label.font
            view.textColor = label.color
        }
        setNeedsLayout()
        animate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let shown else { return }
        // `bounds` and `center`, as the strip carries a transform while it scrolls.
        strip.bounds = CGRect(origin: .zero, size: bounds.size)
        strip.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let width = shown.textWidth.rounded(.up) + 1
        first.frame = CGRect(x: shown.edge, y: 0, width: width, height: bounds.height)
        second.frame = first.frame.offsetBy(dx: shown.travel, dy: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fades.frame = bounds
        let edge = bounds.width > 0 ? Double(shown.edge / bounds.width) : 0
        fades.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    /// Sets the text moving from wherever the clock has it — or, while nothing should move, holds
    /// it there.
    @objc private func animate() {
        guard let shown else { return }
        let travel = shown.travel
        let cycle = shown.startDelay + Double(travel / shown.speed)
        let elapsed = shown.start.map { max(Date().timeIntervalSince($0), 0) } ?? 0
        strip.layer.removeAnimation(forKey: Self.animationKey)
        guard shown.isActive, shown.start != nil, window != nil else {
            let into = elapsed.truncatingRemainder(dividingBy: cycle)
            let offset = max(into - shown.startDelay, 0) * Double(shown.speed)
            strip.transform = CGAffineTransform(translationX: -offset, y: 0)
            return
        }
        strip.transform = .identity
        // Still for `startDelay`, then along at `speed`, over and over.
        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = [0, 0, -travel]
        scroll.keyTimes = [0, NSNumber(value: shown.startDelay / cycle), 1]
        scroll.duration = cycle
        scroll.repeatCount = .infinity
        scroll.isRemovedOnCompletion = false
        scroll.beginTime = strip.layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        strip.layer.add(scroll, forKey: Self.animationKey)
    }
}
