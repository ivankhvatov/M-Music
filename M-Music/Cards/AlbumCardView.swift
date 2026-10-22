import SwiftUI

struct AlbumCardView: View {
    /// What the second line under the album title shows — the artist name (the default, used
    /// everywhere an album can be by a different artist) or the release year (used in
    /// `ArtistAlbumsView`'s grid, where every card is already known to be by this artist).
    enum Subtitle {
        case artist
        case year
    }

    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil
    var subtitle: Subtitle = .artist

    /// Resolved once per `album.id`, in `init`, from a shared memo of signed URLs — `coverArtURL`
    /// signs every call with a fresh random token, so recomputing it on every body evaluation
    /// (e.g. every time a `LazyVGrid` re-renders this cell) makes `CachedAsyncImage` see a "new"
    /// URL each time and re-run its load task. Set here rather than from a `.task`, which made
    /// every cell render once with no URL, once with it, and once more with the image.
    @State private var artworkURL: URL?

    init(album: AlbumID3, zoomNamespace: Namespace.ID? = nil, subtitle: Subtitle = .artist) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        self.subtitle = subtitle
        _artworkURL = State(initialValue: ArtworkRequest.albumCard(album.coverArt ?? album.id.raw).url)
    }

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(
                album.name + (album.version != nil ? (" (" + album.version! + ")") : "")
            )
                .font(.system(size: 14))
                .lineLimit(1)

            Text(subtitleText)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
                .padding(.top, -3)
        }
        .dimmedIfUnavailable(isAvailable)
    }

    /// Nothing is ever "unavailable" while online (everything can still stream) — only offline
    /// does whether this album has *any* downloaded song matter. Not the same question as
    /// `AlbumView.isAlbumDownloaded` (every song downloaded, for the toolbar button). The
    /// `NavigationLink` this card is normally the label of can't be disabled from in here — the
    /// parent view that builds it computes this same expression again for that.
    private var isAvailable: Bool {
        networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw)
    }

    private var subtitleText: String {
        switch subtitle {
        case .artist:
            return album.artist ?? "Unknown Artist"
        case .year:
            return album.year.map(String.init) ?? "Unknown Year"
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // `Color.clear.aspectRatio(1, contentMode: .fit)` establishes the square footprint every
        // card in the grid shares (its side derived from the column's proposed width, same as
        // this used to do directly) — `.overlay` then proposes that resolved square, concretely,
        // to the real artwork below, so a non-square cover can `.fit` within it (longer side
        // matching the square, not stretched to fill it) instead of forcing a 1:1 crop.
        let image = Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // Same URL AlbumView requests (original size, no `size` param), so opening this
                // album reuses the image straight from ImageCache instead of triggering a second
                // fetch — see CachedAsyncImage.
                CachedAsyncImage(url: artworkURL, maxPixelSize: ImageCache.cardMaxPixelSize) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary, lineWidth: 0.15)
                        )
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                }
            }

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
