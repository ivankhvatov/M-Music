import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject private var player = PlayerManager.shared

    /// Bumped on every play/pause tap to restart `PlayPauseBurst`'s animation from scratch.
    @State private var playPauseBurstID = 0

    var body: some View {
        HStack (spacing: 8) {
            PlayerCover(.init(width: 32, height: 32), .init(4))
            PlayerInfo()
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
                    player.togglePlayPause()
                }
                playPauseBurstID += 1
            } label: {
                ZStack {
                    PlayPauseBurst(trigger: playPauseBurstID, color: .mainText, endScale: 1.2)
                        .frame(width: 30, height: 30)
                    if player.isBuffering {
                        ProgressView()
                    } else {
                        // See PlayerView's play/pause button for why there's no
                        // `.contentTransition(.symbolEffect(.replace))` here.
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .symbolEffect(.bounce, value: player.isPlaying)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(.rect)
                .tint(.mainText)
            }
            .padding(.trailing, 10)
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .tint(.mainText)
            }
        }
        .padding(.horizontal, 17)
    }

    func PlayerCover(_ size: CGSize, _ radius: CGFloat) -> some View {
        CachedAsyncImage(url: player.artworkURL) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .scaledToFit()
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    func PlayerInfo() -> some View {
        VStack (alignment: .leading, spacing: 2) {
            MarqueeText(text: player.currentTrack?.title ?? String(localized: "Not Playing"))
                .font(.system(size: 14))
            MarqueeText(text: player.currentTrack?.artist ?? "")
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }
}

#Preview {
    MiniPlayerView()
}
