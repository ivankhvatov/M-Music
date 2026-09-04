import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        HStack (spacing: 8) {
            PlayerCover(.init(width: 32, height: 32), .init(4))
            PlayerInfo()
            Spacer(minLength: 0)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
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
            Image("cover_placeholder")
                .resizable()
                .scaledToFit()
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    func PlayerInfo() -> some View {
        HStack (spacing: 12) {
            VStack (alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 14))
                Text(player.currentTrack?.artist ?? "")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .lineLimit(1)
        }
    }
}

#Preview {
    MiniPlayerView()
}
