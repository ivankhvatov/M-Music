import SwiftUI

/// Square cover artwork with a subtle border and a placeholder background, used by both the
/// compact mini player and the expanded Now Playing screen.
struct TrackArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        let border = UIScreen.hairlineWidth
        ZStack {
            Color(.systemGray5)
                .aspectRatio(1, contentMode: .fit)
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: border / 2)
                .stroke(Color.black.opacity(0.15), lineWidth: border)
        )
    }
}
