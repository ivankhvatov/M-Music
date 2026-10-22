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
        CoverCard(
            transitionID: playlist.id,
            title: playlist.name,
            subtitle: playlist.owner ?? "Unknown Creator",
            artworkURL: artworkURL,
            placeholderSymbol: "music.note.list",
            isAvailable: isAvailable,
            zoomNamespace: zoomNamespace
        )
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
