import SwiftUI

/// The full-screen expanded Now Playing layout: drag grip, large artwork, and playback controls.
struct RegularNowPlaying: View {
    @ObservedObject private var player = PlayerManager.shared
    var size: CGSize
    var colors: [Color]
    var animationNamespace: Namespace.ID

    var body: some View {
        VStack(spacing: 12) {
            grip
                .blendMode(.overlay)

            artwork
                .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
                .frame(height: size.width - Const.horizontalPadding * 2)
                .padding(.vertical, size.height < 700 ? 10 : 30)
                .padding(.horizontal, 25)

            PlayerControls(colors: colors)
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
    }
}

private extension RegularNowPlaying {
    enum Const {
        static let horizontalPadding: CGFloat = 25
    }

    var grip: some View {
        Capsule()
            .fill(.white.secondary)
            .frame(width: 40, height: 5)
    }

    @ViewBuilder
    var artwork: some View {
        let small = !player.isPlaying
        TrackArtworkView(url: player.artworkURL, cornerRadius: 10)
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: small ? 0.13 : 0.33), radius: small ? 3 : 8, y: small ? 3 : 10)
            .padding(small ? 48 : 0)
            .animation(.smooth, value: player.isPlaying)
    }
}
