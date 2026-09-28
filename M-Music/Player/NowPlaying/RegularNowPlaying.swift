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

    var body: some View {
        VStack(spacing: 12) {
            grip
            Color.clear
                .frame(height: RegularNowPlayingLayout.artworkHeight(for: size))
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
            // Everything below the artwork placeholder: the title/artist and scrubber at their
            // natural height, then the button rows spread evenly through the rest. (The scrubber's
            // gap to the title scales with the space available, hence the `GeometryReader`.)
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    PlayerTrackInfo(
                        spacing: geometry.size.height * 0.04,
                        marqueesActive: marqueesActive,
                        marqueeRestartToken: marqueeRestartToken
                    )
                    PlayerControls()
                }
            }
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
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

    var body: some View {
        VStack(spacing: 12) {
            Color.clear
                .frame(width: 70, height: 5)
                .padding(.vertical, 12)
            artwork
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
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
        let small = !player.isPlaying
        let fullSide = RegularNowPlayingLayout.artworkHeight(for: size)
        let shrunkSide = fullSide - RegularNowPlayingLayout.Const.pausedInset * 2
        TrackArtworkView(url: player.artworkURL, cornerRadius: 10)
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: small ? 0.13 : 0.33), radius: small ? 3 : 8, y: small ? 3 : 10)
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
    }

    static func artworkHeight(for size: CGSize) -> CGFloat {
        size.width - Const.horizontalPadding * 2
    }

    static func artworkVerticalPadding(for size: CGSize) -> CGFloat {
        size.height < 700 ? 10 : 30
    }
}
