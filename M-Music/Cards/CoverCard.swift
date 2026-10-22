import SwiftUI

/// The look of an album or playlist card: the cover, a title and a subtitle. Pure — everything it
/// shows comes in as a value (including whether it's available offline, which the *caller*
/// works out), it observes nothing and is `Equatable`, so SwiftUI can skip it when nothing it
/// shows changed. `AlbumCardView` and `PlaylistCardView` wrap it for the screens that observe the
/// downloads themselves; Home uses it directly, with availability computed off the main actor.
struct CoverCard<TransitionID: Hashable>: View, Equatable {
    let transitionID: TransitionID
    let title: String
    let subtitle: String
    let artworkURL: URL?
    /// The SF Symbol on the placeholder while the cover isn't decoded yet.
    let placeholderSymbol: String
    let isAvailable: Bool
    var zoomNamespace: Namespace.ID?
    /// A fixed side for the cover, for a card of known size (Home's carousels). Without it the
    /// cover takes the width it's offered and is square — what a grid cell needs, at the price of
    /// an extra layout negotiation per card.
    var coverSide: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
                .padding(.top, -3)
        }
        .dimmedIfUnavailable(isAvailable)
    }

    @ViewBuilder
    private var artwork: some View {
        // `Color.clear.aspectRatio(1, contentMode: .fit)` establishes the square footprint every
        // card in a grid or carousel shares — `.overlay` then proposes that resolved square,
        // concretely, to the real artwork below, so a non-square cover can `.fit` within it
        // (longer side matching the square, not stretched to fill it) instead of forcing a 1:1 crop.
        let image = square
            .overlay {
                // The original size (no `size` parameter), the same URL the album or playlist
                // screen requests, so opening it reuses the image straight from `ImageCache`.
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
                            Image(systemName: placeholderSymbol)
                                .foregroundStyle(.secondary)
                        }
                }
            }

        if let zoomNamespace {
            image.matchedTransitionSource(id: transitionID, in: zoomNamespace)
        } else {
            image
        }
    }

    @ViewBuilder
    private var square: some View {
        if let coverSide {
            Color.clear.frame(width: coverSide, height: coverSide)
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }
}
