import SwiftUI

/// The full-screen expanded Now Playing layout's chrome — drag grip and playback controls — with
/// an invisible placeholder reserving the artwork's spot. Kept separate from the artwork itself
/// (see `RegularArtwork`) so `ExpandableNowPlaying` can swap the two independently: nesting a
/// `matchedGeometryEffect` view inside a `.transition()`-ed parent breaks that parent's own
/// removal animation (it cuts short instead of animating), which is what made this chrome vanish
/// instantly on collapse instead of fading out with the rest of the shrink.
struct RegularChrome: View {
    var size: CGSize
    var colors: [Color]
    var onCollapse: () -> Void
    var marqueesActive = true
    var marqueeRestartToken = 0
    /// Whether the up-next queue is showing instead of the big artwork — see `lowerRegion`.
    @Binding var showsQueue: Bool

    var body: some View {
        VStack(spacing: 12) {
            grip
            Color.clear
                .frame(height: RegularNowPlayingLayout.artworkHeight(for: size, showsQueue: showsQueue))
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size, showsQueue: showsQueue))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
            lowerRegion
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
    }

    /// Everything below the artwork placeholder, top to bottom: the title/artist, the queue list,
    /// the scrubber, then the button rows.
    ///
    /// The same views are laid out in both modes, with different numbers, so toggling the queue
    /// animates as a move rather than a swap. Without the queue the title sits at its natural
    /// height, the list has none, and the button rows spread through the space that's left. With it,
    /// the title is pulled up (by a negative bottom padding that cancels the space it took, plus an
    /// offset in `PlayerTrackTitle`) onto the artwork's row beside it, the list takes all the room
    /// the button rows don't need, and those shrink to their natural height.
    private var lowerRegion: some View {
        // The scrubber's gap to the title scales with the space available, hence the reader.
        GeometryReader { geometry in
            let spacing = geometry.size.height * 0.04
            VStack(spacing: 0) {
                PlayerTrackTitle(
                    showsQueue: showsQueue,
                    width: size.width,
                    marqueesActive: marqueesActive,
                    marqueeRestartToken: marqueeRestartToken
                )
                .padding(.bottom, showsQueue ? -RegularNowPlayingLayout.queueTitleRise : spacing * 2)
                // Always mounted and pinned to the top of this frame, which is itself pinned to the
                // title's bottom edge: the list is carried up (and back down) rigidly with the
                // title, at exactly its speed, rising out from behind the scrubber below — whose
                // top edge the clip cuts it off at — rather than being revealed in place by the
                // artwork shrinking away above it. (A move transition instead measured its
                // distance against the frame's own, still-growing height, so it lagged the title.)
                PlayerQueueList()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // The title travels its layout move plus its own offset (`queueTitleRise`); the
                    // list, hung from the title's layout position, gets that offset too, so the
                    // two cover the same distance in the same time.
                    .offset(y: showsQueue ? 0 : RegularNowPlayingLayout.queueTitleRise)
                    // Fades along with the move, rather than only being cut off at the scrubber.
                    .opacity(showsQueue ? 1 : 0)
                    .allowsHitTesting(showsQueue)
                    .accessibilityHidden(!showsQueue)
                // Full width even while empty, or the clip would grow out from the center as the
                // list comes in and shrink back into it as it leaves.
                .frame(maxWidth: .infinity, maxHeight: showsQueue ? .infinity : 0)
                // Clips the list to this frame and fades its top and bottom edges. It's applied
                // here, to the fixed frame, rather than inside the list, so the fades are there
                // while the list slides in or out too.
                .mask { PlayerQueueList.FadeMask() }
                // Reaches down over the empty top of the scrubber's frame (its bar sits a little
                // below it), so the fade ends right on the bar rather than a gap above it. A
                // negative padding, after the mask: the frame — and so the mask — gets that much
                // taller, the layout doesn't.
                .padding(.bottom, showsQueue ? -RegularNowPlayingLayout.scrubberBarInset : 0)
                PlayerProgress(spacing: spacing)
                PlayerControls(showsQueue: $showsQueue)
            }
        }
    }

    private var grip: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(width: 70, height: 5)
            .padding(.vertical, 12)
            .contentShape(.rect)
            .onTapGesture(perform: onCollapse)
    }
}

/// The large expanded-state artwork alone, positioned via a placeholder-grip/trailing-spacer
/// VStack that mirrors `RegularChrome`'s own layout exactly (same spacing, same grip-sized first
/// child) so the two align pixel-for-pixel without duplicating layout constants by hand. See
/// `RegularChrome`'s doc comment for why the two are kept apart.
struct RegularArtwork: View {
    @ObservedObject private var player = PlayerManager.shared
    var size: CGSize
    var animationNamespace: Namespace.ID
    /// With the queue showing, the artwork shrinks to a small square at the top left — the same
    /// view with different numbers, so the toggle animates as a shrink and move.
    var showsQueue = false

    var body: some View {
        VStack(spacing: 12) {
            Color.clear
                .frame(width: 70, height: 5)
                .padding(.vertical, 12)
            artwork
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size, showsQueue: showsQueue))
                .padding(.horizontal, showsQueue ? NowPlayingLayout.cardPaddings : RegularNowPlayingLayout.Const.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: showsQueue ? .leading : .center)
            Spacer(minLength: 0)
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
    }

    /// The paused/playing shrink is expressed as this view's own size (fed into
    /// `matchedGeometryEffect`) rather than, as it was, a fixed-size box with inner padding —
    /// `matchedGeometryEffect` only ever interpolates the frame it's actually given, so a fixed
    /// outer frame with the shrink hidden inside as padding never took part in the expand/collapse
    /// handoff to `CompactArtwork`: collapsing snapped straight back to full size before the
    /// (unrelated, un-inset) compact frame took over, instead of shrinking smoothly into it.
    @ViewBuilder
    private var artwork: some View {
        // The paused shrink doesn't apply to the small queue-mode artwork.
        let small = !player.isPlaying && !showsQueue
        let fullSide = RegularNowPlayingLayout.artworkHeight(for: size, showsQueue: showsQueue)
        let shrunkSide = fullSide - RegularNowPlayingLayout.Const.pausedInset * 2
        let softShadow = small || showsQueue
        TrackArtworkView(url: player.artworkURL, cornerRadius: showsQueue ? 6 : 10)
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: small ? 0.13 : 0.33), radius: softShadow ? 3 : 8, y: softShadow ? 3 : 10)
            .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
            .frame(width: small ? shrunkSide : fullSide, height: small ? shrunkSide : fullSide)
            // Reserves the full, un-shrunk square regardless of `small`, so the smaller box stays
            // centered with even margins instead of the surrounding VStack reflowing around it.
            .frame(width: fullSide, height: fullSide)
            .animation(.smooth, value: player.isPlaying)
    }
}

enum RegularNowPlayingLayout {
    enum Const {
        static let horizontalPadding: CGFloat = 25
        /// How much the artwork shrinks (per side) while paused — see `RegularArtwork.artwork`.
        static let pausedInset: CGFloat = 48
        /// Side of the artwork's small top-left square while the queue is showing.
        static let queueArtworkSide: CGFloat = 60
    }

    /// Side of the artwork square — full-width normally, small with the queue showing.
    static func artworkHeight(for size: CGSize, showsQueue: Bool = false) -> CGFloat {
        showsQueue ? Const.queueArtworkSide : size.width - Const.horizontalPadding * 2
    }

    static func artworkVerticalPadding(for size: CGSize, showsQueue: Bool = false) -> CGFloat {
        showsQueue ? 0 : (size.height < 700 ? 10 : 30)
    }

    /// How far right of its normal edge the title/artist start with the queue showing: past the
    /// artwork and a gap.
    static let queueTitleInset = Const.queueArtworkSide + 14

    /// How far below the top of the scrubber's 60pt frame its bar starts: the bar and the time
    /// labels under it (about 31pt together) are centered in that frame, leaving ~14pt above.
    static let scrubberBarInset: CGFloat = 14

    /// How far up the title/artist move with the queue showing: from just below the artwork's row
    /// (the artwork's height plus `RegularChrome`'s 12pt spacing) onto it.
    static let queueTitleRise = Const.queueArtworkSide + 12
}

extension Animation {
    /// The move between the big-artwork and queue layouts.
    static let playerQueueAnimationDuration: TimeInterval = 0.4
    static var playerQueueAnimation: Animation { .smooth(duration: playerQueueAnimationDuration) }
}
