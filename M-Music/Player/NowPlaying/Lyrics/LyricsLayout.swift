import UIKit

/// Where each synced line sits, worked out once, off the main thread, from the lines' text and the
/// width they're laid out in.
///
/// The lyrics are a stack of fixed-height slots — a real row for the lines near what's on screen,
/// an empty spacer of exactly the same height for the rest — so the scroll view's content height is
/// known and never changes while the user scrolls. (A lazy stack, which has to guess the height of
/// the rows it hasn't built yet, kept correcting its guess as it built them, and each correction
/// nudged the scroll position: that was the twitching.) Building only the near rows keeps opening
/// and line changes cheap, which a stack of every row isn't.
struct LyricsLayout: Equatable, Sendable {
    /// The gap below each sung line.
    static let rowSpacing: CGFloat = 20
    /// How much larger the current line is drawn.
    static let currentScale: CGFloat = 1.16
    /// The font the lines are set in.
    static let fontSize: CGFloat = 26

    /// The width a line's text is laid out in, for lyrics `width` points wide: the line is laid
    /// out narrower, so that scaled up it still ends where the others do instead of poking out past
    /// the right margin.
    static func textWidth(forViewWidth width: CGFloat) -> CGFloat {
        (width - NowPlayingLayout.cardPaddings * 2) / currentScale
    }

    /// The range of lines whose rows exist.
    struct Window: Equatable, Sendable {
        var start = 0
        /// One past the last.
        var end = 0

        func contains(_ index: Int) -> Bool { index >= start && index < end }

        /// The smallest window holding both — the lines between them too.
        func union(_ other: Window) -> Window {
            Window(start: min(start, other.start), end: max(end, other.end))
        }
    }

    /// The height of each line's text; 0 for a break, which has no row unless it's current.
    let textHeights: [CGFloat]
    /// Where each line's slot starts, and, last, the total.
    private let offsets: [CGFloat]

    init(timeline: LyricsTimeline, textWidth: CGFloat) {
        let font = UIFont.systemFont(ofSize: Self.fontSize, weight: .bold)
        let heights = timeline.lines.map { line -> CGFloat in
            guard !line.isBreak else { return 0 }
            let bounds = (line.text as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin,
                attributes: [.font: font],
                context: nil
            )
            return ceil(bounds.height)
        }
        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            offsets.append(y)
            if height > 0 { y += height + Self.rowSpacing }
        }
        offsets.append(y)
        self.textHeights = heights
        self.offsets = offsets
    }

    /// The lines whose slots reach into `top ..< bottom` (positions in the scroll content), with a
    /// viewport's worth more on each side so that a flick finds its rows already built.
    func window(top: CGFloat, bottom: CGFloat) -> Window {
        let margin = max(bottom - top, 300)
        return window(reaching: top - margin, to: bottom + margin)
    }

    /// The lines near `index`, for when the lyrics are about to jump or scroll there: what
    /// `window(top:bottom:)` finds once the line is at the top of a view about this tall.
    func window(around index: Int) -> Window {
        let y = offsets[min(max(index, 0), offsets.count - 1)]
        return window(top: y - 56, bottom: y - 56 + 520)
    }

    /// Fewer than `window(around:)`, for when the lyrics first come up: just what's showing and a
    /// little way beyond, so that coming up costs as little as it can. The rest is built a moment
    /// later, once the panel has finished moving.
    func initialWindow(around index: Int) -> Window {
        let y = offsets[min(max(index, 0), offsets.count - 1)]
        return window(reaching: y - 56 - 250, to: y - 56 + 520 + 350)
    }

    private func window(reaching top: CGFloat, to bottom: CGFloat) -> Window {
        let count = textHeights.count
        // First line whose slot ends after `top`.
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid + 1] > top { high = mid } else { low = mid + 1 }
        }
        let start = low
        // First line that starts at or after `bottom`.
        low = start
        high = count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] >= bottom { high = mid } else { low = mid + 1 }
        }
        return Window(start: start, end: low)
    }
}
