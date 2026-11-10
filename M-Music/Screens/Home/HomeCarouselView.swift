import SwiftUI

/// One Home carousel, drawn from its prebuilt `HomeCarouselModel`. Nothing in it observes anything
/// and `body` does no work beyond the loop: it's `Equatable` on the model, so while Home re-renders
/// for other reasons a carousel — and its twenty cards — whose model is unchanged is skipped.
///
/// Each carousel owns its zoom namespace: the same album can appear in several carousels at once,
/// and a namespace shared between them would make the album screen zoom out of whichever card is
/// highest on screen instead of the one that was tapped.
struct HomeCarouselView: View, Equatable {
    let model: HomeCarouselModel

    static func == (lhs: HomeCarouselView, rhs: HomeCarouselView) -> Bool {
        lhs.model == rhs.model
    }

    @Namespace private var zoomNamespace
    /// The last tapped card, drawn above its neighbors so the zoom transition isn't covered by them.
    @State private var raisedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so only the cards scrolled into view build and start loading artwork.
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.cards) { card in
                        link(for: card)
                    }
                }
                .padding(.horizontal, 16)
            }
            // The zoom transition's source is a card inside this scroll view; with clipping on,
            // the artwork is cut off at the scroll view's bounds while it flies in and out.
            .scrollClipDisabled()
        }
        // Built, so near the screen: the carousels around it are warmed before they're reached.
        .onAppear { HomeWarmCoordinator.shared.carouselAppeared(source: model.source) }
    }

    @ViewBuilder
    private var title: some View {
        switch model.title {
        case .kind(let kind): Text(kind.title)
        case .verbatim(let name): Text(verbatim: name)
        }
    }

    private func link(for card: HomeCard) -> some View {
        NavigationLink(destination: LazyDestination { destination(for: card) }) {
            CoverCard(
                transitionID: card.routeID,
                title: card.title,
                subtitle: card.subtitle,
                artworkURL: card.artworkURL,
                placeholderSymbol: symbol(for: card),
                isAvailable: card.isAvailable,
                zoomNamespace: zoomNamespace,
                coverSide: 160
            )
            .equatable()
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { raisedID = card.id })
        .zIndex(raisedID == card.id ? 1 : 0)
        .disabled(!card.isAvailable)
        // A tiny report to the coordinator, which does the rest off the main actor.
        .onAppear { HomeWarmCoordinator.shared.cardAppeared(source: model.source, index: card.index) }
        .modifier(PlaylistWarm(card: card))
    }

    @ViewBuilder
    private func destination(for card: HomeCard) -> some View {
        switch card.content {
        case .album(let album): AlbumView(album: album, zoomNamespace: zoomNamespace)
        case .playlist(let playlist): PlaylistView(playlist: playlist, zoomNamespace: zoomNamespace)
        }
    }

    private func symbol(for card: HomeCard) -> String {
        if case .playlist = card.content { return "music.note.list" }
        return "music.note"
    }
}

/// A playlist card also warms what its own screen will show once it has stayed on screen a moment
/// (see `ImageWarmer.warmPlaylist`). Only playlist cards pay for the task: it used to be created for
/// every card on every appearance.
private struct PlaylistWarm: ViewModifier {
    let card: HomeCard

    @ViewBuilder
    func body(content: Content) -> some View {
        if case .playlist(let playlist) = card.content {
            content.task(id: card.id) {
                await ImageWarmer.shared.warmPlaylist(id: playlist.id.raw, artworkId: playlist.coverArt ?? playlist.id.raw)
            }
        } else {
            content
        }
    }
}
