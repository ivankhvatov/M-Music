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

    /// Computed once per `playlist.id` and cached — see `AlbumCardView.artworkURL`'s doc comment
    /// for why: `coverArtURL` signs every call with a fresh random token, so recomputing it on
    /// every body evaluation would make `CachedAsyncImage` see a "new" URL each time.
    @State private var artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(playlist.name)
                .font(.system(size: 15))
                .lineLimit(1)

            Text(playlist.owner ?? "Unknown Creator")
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .task(id: playlist.id) {
            artworkURL = try? SubsonicClient.shared.coverArtURL(forId: playlist.coverArt ?? playlist.id.raw)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // Same URL PlaylistView requests (original size, no `size` param), so opening this
        // playlist reuses the image straight from ImageCache instead of triggering a second
        // fetch — see CachedAsyncImage.
        let image = CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary, lineWidth: 0.15)
        )

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
