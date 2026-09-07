import SwiftUI

struct AlbumCardView: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    /// Computed once per `album.id` and cached, rather than inline in `artwork` — `coverArtURL`
    /// signs every call with a fresh random token, so recomputing it on every body evaluation
    /// (e.g. every time a `LazyVGrid` re-renders this cell) makes `CachedAsyncImage` see a "new"
    /// URL each time and re-run its load task, even though `ImageCache` itself dedupes by a
    /// token-stripped key underneath. At grid scale that's a lot of redundant task churn.
    @State private var artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(
                album.name + (album.version != nil ? (" (" + album.version! + ")") : "")
            )
                .font(.system(size: 15))
                .lineLimit(1)

            Text(album.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .task(id: album.id) {
            artworkURL = try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // Same URL AlbumView requests (original size, no `size` param), so opening this album
        // reuses the image straight from ImageCache instead of triggering a second fetch —
        // see CachedAsyncImage.
        let image = CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
