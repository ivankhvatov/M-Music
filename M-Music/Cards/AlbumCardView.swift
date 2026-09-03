import SwiftUI

struct AlbumCardView: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(album.name)
                .font(.system(size: 15))
                .lineLimit(1)

            Text(album.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let image = AsyncImage(url: try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw, size: 300)) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary, lineWidth: 0.15)
        )

        if let zoomNamespace {
            image.matchedTransitionSource(id: album.id, in: zoomNamespace)
        } else {
            image
        }
    }
}

// Preview Provider
#Preview {
    ZStack {
        AlbumCardView(
            album: AlbumID3(
                id: "1", name: "Too Fast to Die", artist: "Archspire", artistId: nil,
                coverArt: nil, songCount: 9, duration: 2707, playCount: nil, created: nil,
                starred: nil, year: 2026, genre: "Death Metal", userRating: nil
            )
        )
    }
}
