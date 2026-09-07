import SwiftUI

/// Track title/artist, the scrubber, transport buttons, and volume — the lower half of the
/// expanded Now Playing screen.
struct PlayerControls: View {
    @ObservedObject private var player = PlayerManager.shared
    var colors: [Color]

    var body: some View {
        GeometryReader {
            let size = $0.size
            let spacing = size.verticalSpacing
            VStack(spacing: 0) {
                VStack(spacing: spacing) {
                    trackInfo
                    TimingIndicator(spacing: spacing)
                        .padding(.top, spacing)
                        .padding(.horizontal, NowPlayingLayout.cardPaddings)
                }
                .frame(height: size.height / 2.5, alignment: .top)
                PlayerButtons(spacing: size.width * 0.14)
                    .padding(.horizontal, NowPlayingLayout.cardPaddings)
                footer
                    .padding(.horizontal, NowPlayingLayout.cardPaddings)
                    .frame(height: size.height / 2.5, alignment: .bottom)
            }
        }
    }
}

private extension CGSize {
    var verticalSpacing: CGFloat { height * 0.04 }
}

private extension PlayerControls {
    var trackInfo: some View {
        HStack(alignment: .center, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(text: player.currentTrack?.title ?? String(localized: "Not Playing"))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                MarqueeText(text: player.currentTrack?.artist ?? "")
                    .foregroundStyle(Color.transparentWhite)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                player.toggleStarred()
            } label: {
                Image(systemName: player.isCurrentTrackStarred ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.transparentWhite)
            }
        }
        .padding(.horizontal, NowPlayingLayout.cardPaddings)
    }

    var footer: some View {
        HStack {
            Spacer()
            AirPlayButton()
                .foregroundStyle(Color.transparentWhite)
        }
    }
}
