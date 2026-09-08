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

    var body: some View {
        VStack(spacing: 12) {
            grip
            Color.clear
                .frame(height: RegularNowPlayingLayout.artworkHeight(for: size))
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
            PlayerControls(colors: colors)
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
                .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
                .frame(height: RegularNowPlayingLayout.artworkHeight(for: size))
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
            Spacer(minLength: 0)
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
    }

    @ViewBuilder
    private var artwork: some View {
        let small = !player.isPlaying
        TrackArtworkView(url: player.artworkURL, cornerRadius: 10)
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: small ? 0.13 : 0.33), radius: small ? 3 : 8, y: small ? 3 : 10)
            .padding(small ? 48 : 0)
            .animation(.smooth, value: player.isPlaying)
    }
}

enum RegularNowPlayingLayout {
    enum Const {
        static let horizontalPadding: CGFloat = 25
    }

    static func artworkHeight(for size: CGSize) -> CGFloat {
        size.width - Const.horizontalPadding * 2
    }

    static func artworkVerticalPadding(for size: CGSize) -> CGFloat {
        size.height < 700 ? 10 : 30
    }
}
