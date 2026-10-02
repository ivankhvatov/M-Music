//
//  PlaylistCardView.swift
//  M-Music
//
//  Created by Ivan on 13.09.2026.
//

import SwiftUI

struct PlaylistCardView: View {
    let playlist: PlaylistSummary
    var zoomNamespace: Namespace.ID? = nil

    /// Resolved once per `playlist.id`, in `init` — see `AlbumCardView.artworkURL`'s doc comment
    /// for why: `coverArtURL` signs every call with a fresh random token, so recomputing it on
    /// every body evaluation would make `CachedAsyncImage` see a "new" URL each time.
    @State private var artworkURL: URL?

    init(playlist: PlaylistSummary, zoomNamespace: Namespace.ID? = nil) {
        self.playlist = playlist
        self.zoomNamespace = zoomNamespace
        _artworkURL = State(initialValue: ArtworkRequest.playlistCard(playlist.coverArt ?? playlist.id.raw).url)
    }

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(playlist.name)
                .font(.system(size: 14))
                .lineLimit(1)

            Text(playlist.owner ?? "Unknown Creator")
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
                .padding(.top, -3)
        }
        .dimmedIfUnavailable(isAvailable)
        // Warms what the playlist's own screen will show (header, first songs' thumbnails) once
        // the card has stayed on screen a moment — see `ImageWarmer`.
        .task(id: playlist.id) {
            await ImageWarmer.shared.warmPlaylist(id: playlist.id.raw, artworkId: playlist.coverArt ?? playlist.id.raw)
        }
    }

    /// Nothing is ever "unavailable" while online — only offline does whether this playlist has
    /// *any* downloaded song matter. Not the same question as `PlaylistView.isPlaylistDownloaded`
    /// (every song downloaded, for the toolbar button). `nil` (this playlist's songs were never
    /// cached) reads as "no" rather than "unknown" — there's nothing to cross-reference against.
    /// The `NavigationLink` this card is normally the label of can't be disabled from in here —
    /// the parent view that builds it computes this same expression again for that.
    private var isAvailable: Bool {
        guard !networkMonitor.isOnline else { return true }
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return songIds.contains { downloads.isDownloaded($0) }
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
                // Same URL PlaylistView requests (original size, no `size` param), so opening
                // this playlist reuses the image straight from ImageCache instead of triggering
                // a second fetch — see CachedAsyncImage.
                CachedAsyncImage(url: artworkURL, maxPixelSize: ImageCache.cardMaxPixelSize, loadDelay: .milliseconds(50)) { image in
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
                            Image(systemName: "music.note.list")
                                .foregroundStyle(.secondary)
                        }
                }
            }

        if let zoomNamespace {
            image.matchedTransitionSource(id: playlist.id, in: zoomNamespace)
        } else {
            image
        }
    }
}

#Preview {
    ZStack {
        PlaylistCardView(
            playlist: PlaylistSummary(
                id: "1", name: "Road Trip", comment: nil, owner: "ivan",
                public: true, songCount: 24, duration: 5400, created: nil, changed: nil, coverArt: nil
            )
        )
    }
}
