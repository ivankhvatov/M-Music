import SwiftUI

/// A single line of text that, when it's too wide for the space it's given, slowly scrolls left
/// to reveal the rest and back again — instead of truncating with an ellipsis, like the
/// now-playing title/artist in Apple Music. Renders as plain static text when it already fits.
struct MarqueeText: View {
    let text: String

    /// Scroll speed, in points per second.
    var speed: CGFloat = 30
    /// How long to hold at each end before scrolling to the other.
    var edgePause: Double = 1.5

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// True for the duration of an actual scroll animation — as opposed to `offset` itself, which
    /// jumps to its new target the instant `withAnimation` is called, before the motion has
    /// visually happened. Driving the fade off `offset` directly made it read "arrived" for the
    /// whole trip, so only the edge already at rest ever faded; this tracks the real motion.
    @State private var isScrolling = false

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    /// Edge fade width, in points — capped so it doesn't swallow the whole label in a narrow
    /// container like the mini player.
    private var fadeWidth: CGFloat { containerWidth > 0 ? min(16, containerWidth / 4) : 0 }

    /// True while resting at the un-scrolled position, where the label's first letter is already
    /// fully visible — the leading fade would otherwise dim it for no reason.
    private var isAtStart: Bool { !isScrolling && offset <= 0 }
    /// True while resting fully scrolled, where the label's last letter is already fully visible.
    private var isAtEnd: Bool { !isScrolling && overflow > 0 && offset >= overflow }

    var body: some View {
        // A plain, compressible Text sized exactly the way the original (non-marquee) label was:
        // it resolves to whatever width the surrounding layout actually gives it. Using that
        // resolved width as `containerWidth` — rather than trying to make the real label greedy —
        // keeps this a well-behaved participant in HStacks/Spacers like any other Text.
        Text(text)
            .lineLimit(1)
            .hidden()
            .background(WidthReader(width: $containerWidth))
            .overlay(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: -offset)
                    .background(WidthReader(width: $textWidth))
            }
            .clipped()
            .mask(edgeFadeMask)
            .task(id: "\(text)|\(overflow)") {
                await runMarquee()
            }
    }

    /// Fades the label out at its own edges while it's actively scrolling, like the now-playing
    /// marquee in Apple Music — plain opaque otherwise, so static (fitting) text isn't dimmed.
    /// Each edge's fade drops out while resting at that edge, so it never dims the letter
    /// already sitting fully visible there.
    @ViewBuilder
    private var edgeFadeMask: some View {
        if overflow > 0, containerWidth > 0 {
            LinearGradient(
                stops: [
                    .init(color: isAtStart ? .black : .clear, location: 0),
                    .init(color: .black, location: fadeWidth / containerWidth),
                    .init(color: .black, location: 1 - fadeWidth / containerWidth),
                    .init(color: isAtEnd ? .black : .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .animation(.easeInOut(duration: 0.3), value: isScrolling)
        } else {
            Color.black
        }
    }

    private func runMarquee() async {
        offset = 0
        isScrolling = false
        guard overflow > 0 else { return }

        let duration = Double(overflow / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(edgePause))
            guard !Task.isCancelled else { return }
            isScrolling = true
            withAnimation(.linear(duration: duration)) { offset = overflow }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            isScrolling = false

            try? await Task.sleep(for: .seconds(edgePause))
            guard !Task.isCancelled else { return }
            isScrolling = true
            withAnimation(.linear(duration: duration)) { offset = 0 }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }
}

/// Reports the width the layout system actually resolved for this view back into `width`,
/// without affecting the size of whatever it's attached to as a background.
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newValue in width = newValue }
        }
    }
}
