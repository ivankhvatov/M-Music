//
//  PlaylistView.swift
//  M-Music
//
//  Created by Ivan on 13.09.2026.
//

import SwiftUI

struct PlaylistView: View {
    let playlist: PlaylistSummary
    var zoomNamespace: Namespace.ID? = nil

    private let client = SubsonicClient.shared
    /// Not `@ObservedObject`: see the identical comment on `AlbumView.player` — this view only
    /// ever calls `player.play(queue:startAt:)`, never reads a `@Published` property in `body`.
    private let player = PlayerManager.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.displayScale) private var displayScale
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInPlaylists) private var showUnavailableInPlaylists = true

    @State private var songs: [Child] = []
    @State private var isLoadingSongs = true
    @State private var loadError: String?

    @State private var backgroundColor: Color

    /// See `AlbumView.artworkURL`'s doc comment — computed synchronously in `init` for the same
    /// reason: a real URL ready at first render lets an already-cached cover (e.g. from
    /// `PlaylistCardView`, which requests this same URL) appear immediately with no placeholder
    /// flash.
    @State private var artworkURL: URL?

    @State private var showingRemoveDownloadConfirmation = false

    /// Point size artwork renders at in a song row — mirrors `SongsListView.rowArtworkSize`.
    private let rowArtworkSize: CGFloat = 44

    init(playlist: PlaylistSummary, zoomNamespace: Namespace.ID? = nil) {
        self.playlist = playlist
        self.zoomNamespace = zoomNamespace
        _backgroundColor = State(initialValue: Color(.systemBackground))
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: playlist.coverArt ?? playlist.id.raw))
    }

    var body: some View {
        Group {
            if let zoomNamespace {
                playlistList
                    .navigationTransition(.zoom(sourceID: playlist.id, in: zoomNamespace))
            } else {
                playlistList
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadSongs()
        }
    }

    var playlistList: some View {
        List {
            VStack(alignment: .leading) {
                playlistHeader()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.darkened())

            trackListSection()

            playlistFooter()
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 16, trailing: 16))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(backgroundColor.darkened().ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .toolbar {
            downloadButton
            moreButton
        }
        .tint(.primary)
    }

    /// Stale-while-revalidate: shows this playlist's cached songs immediately (no spinner) if
    /// any are cached, then revalidates against the server in the background and only touches
    /// the displayed list (and re-caches) if the fresh result actually differs from what's shown.
    private func loadSongs() async {
        if songs.isEmpty, let cached = await LibraryCacheDatabase.shared.cachedPlaylistSongs(playlistId: playlist.id.raw) {
            await MainActor.run {
                songs = cached
                isLoadingSongs = false
            }
        }

        do {
            let full = try await client.getPlaylist(id: playlist.id.raw)
            let entries = full.entry ?? []
            let changed = entries != songs
            await MainActor.run {
                isLoadingSongs = false
                loadError = nil
                if changed { songs = entries }
            }
            if changed {
                await LibraryCacheDatabase.shared.cachePlaylistSongs(entries, playlistId: playlist.id.raw)
            }
        } catch {
            // Offline, or the request otherwise failed — keep showing whatever's already on
            // screen (cache, or an earlier successful fetch); only surface an error if there's
            // truly nothing to show.
            await MainActor.run {
                isLoadingSongs = false
                if songs.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    func trackListSection() -> some View {
        if isLoadingSongs {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
        } else {
            // Not a single row holding a hand-stacked `VStack` of all songs (which is how
            // `AlbumView.trackList` does it): that shape ties every separator's vertical
            // position to the cumulative height of every row above it, and `SongRow`'s
            // text-driven heights routinely don't sum to a whole number of physical pixels —
            // the hairline then straddles two pixel rows and gets antialiased into a fainter,
            // uneven line, or effectively disappears, differently per row and per rebuild. One
            // real `List` row per song sidesteps that: each row (and its separator overlay) is
            // laid out from its own height alone.
            trackList()
        }
    }

    /// Matches the leading edge of a `SongRow`'s title: the artwork's frame width plus its
    /// spacing to the title (mirrors `AlbumView.trackTitleLeadingInset`, adjusted for `SongRow`'s
    /// wider artwork in place of `TrackRow`'s track-number column).
    private var trackTitleLeadingInset: CGFloat { rowArtworkSize + 12 }

    /// One real `List` row per song. The top/bottom boundary rules are overlays on the
    /// first/last row rather than separator rows of their own — a `List` row is never shorter
    /// than the system's default minimum row height, so a standalone row holding only a hairline
    /// renders as a mostly-empty ~44pt row, not a thin rule.
    ///
    /// Every row's own insets are otherwise zero (see the fix for the previous "large top
    /// padding" bug), so the first/last row additionally get a bit of extra top/bottom inset
    /// here — deliberately, rather than relying on whatever default row inset a single
    /// `AlbumView`-style row would have picked up — to keep the action buttons and footer from
    /// sitting flush against the tracklist's boundary rules.
    /// `songs`, minus any "Show unavailable in playlists" would hide (offline + not downloaded).
    /// Feeds `trackList()`'s `ForEach` directly — see `AlbumView.visibleSongs`'s identical doc
    /// comment for why a hidden track must never be constructed at all.
    private var visibleSongs: [Child] {
        guard !networkMonitor.isOnline, !showUnavailableInPlaylists else { return songs }
        return songs.filter { downloads.isDownloaded($0.id.raw) }
    }

    func trackList() -> some View {
        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, track in
            Button {
                playTrack(at: index)
            } label: {
                SongRow(track: track, rowArtworkSize: rowArtworkSize, displayScale: displayScale)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.darkened())
            .listRowInsets(EdgeInsets(
                top: index == 0 ? 12 : 0,
                leading: 16,
                bottom: index == visibleSongs.count - 1 ? 12 : 0,
                trailing: 16
            ))
            .overlay(alignment: .top) {
                if index == 0 {
                    trackSeparator()
                }
            }
            .overlay(alignment: .bottom) {
                if index < visibleSongs.count - 1 {
                    trackSeparator()
                        .padding(.leading, trackTitleLeadingInset)
                } else {
                    trackSeparator()
                }
            }
        }
    }

    /// See `AlbumView.trackSeparator`'s doc comment for why this is a fixed-height rule rather
    /// than a plain `Divider()`.
    private func trackSeparator() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.75))
            .frame(height: 1 / displayScale)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// See `AlbumView.playableSongs`'s identical doc comment.
    private var playableSongs: [Child] {
        networkMonitor.isOnline ? songs : songs.filter { downloads.isDownloaded($0.id.raw) }
    }

    private func playTrack(at index: Int) {
        let queue = playableSongs
        guard let startAt = queue.firstIndex(where: { $0.id == visibleSongs[index].id }) else { return }
        player.play(queue: queue, startAt: startAt)
    }

    private func shuffle() {
        let queue = playableSongs
        guard !queue.isEmpty else { return }
        player.play(queue: queue.shuffled(), startAt: 0)
    }

    private var trackCountAndDuration: String {
        let totalMinutes = playlist.duration / 60
        let songsText = String(localized: "\(playlist.songCount) songs")
        let minutesText = String(localized: "\(totalMinutes) minutes")
        return "\(songsText), \(minutesText)"
    }

    func playlistFooter() -> some View {
        Text(trackCountAndDuration)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func playlistArtwork() -> some View {
        // Same URL PlaylistCardView requests (original size, no `size` param), so this reuses the
        // image straight from ImageCache instead of triggering a second fetch.
        CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .scaledToFit()
                .onAppear {
                    if let color = image.averageColor() {
                        backgroundColor = color
                    }
                }
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
        }
        .frame(maxWidth: 270, maxHeight: 270)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary, lineWidth: 0.15)
        )
        .shadow(color: .black.opacity(0.5), radius: 20)
    }

    /// `playlist.changed`, parsed — Navidrome reports it as an ISO 8601 timestamp, with or
    /// without fractional seconds depending on the field.
    private var updatedDate: Date? {
        guard let changed = playlist.changed else { return nil }
        return Self.iso8601Fractional.date(from: changed) ?? Self.iso8601.date(from: changed)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    private var updatedText: String? {
        guard let updatedDate else { return nil }
        let calendar = Calendar.current
        let daysAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: updatedDate),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0

        switch daysAgo {
        case ...0:
            return String(localized: "Updated today")
        case 1:
            return String(localized: "Updated yesterday")
        default:
            return String(localized: "Updated \(daysAgo) days ago")
        }
    }

    func playlistDetails() -> some View {
        Group {
            if let updatedText {
                Text(updatedText)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    func playlistHeader() -> some View {
        HStack(alignment: .center) {
            Spacer()
            VStack(alignment: .center, spacing: 6) {
                playlistArtwork()
                Text(playlist.name)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 15)
                Text(playlist.owner ?? "Unknown Creator")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                playlistDetails()
                    .multilineTextAlignment(.center)

                actionButtons()
                    .padding(.top, 16)
            }
            Spacer()
        }
    }

    func actionButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                shuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
            .disabled(songs.isEmpty)

            Button {
                playTrack(at: 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                    Text("Play")
                        .font(.system(size: 16))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(backgroundColor.darkened())
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .disabled(songs.isEmpty)

            Button {} label: {
                Image(systemName: "pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Whether every song in the playlist has been downloaded — the toolbar button downloads the
    /// whole playlist if not, or offers to remove it if so.
    private var isPlaylistDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id.raw) }
    }

    @ToolbarContentBuilder
    private var downloadButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if isPlaylistDownloaded {
                    showingRemoveDownloadConfirmation = true
                } else {
                    downloads.downloadAlbum(songs)
                }
            } label: {
                Image(systemName: isPlaylistDownloaded ? "checkmark" : "arrow.down")
                    .foregroundStyle(.primary)
            }
            .disabled(songs.isEmpty)
            .confirmationDialog(
                "Delete the playlist from this device?",
                isPresented: $showingRemoveDownloadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    // Not `downloads.removeAlbum(albumId:)` — that filters downloaded records by
                    // a single shared album id, which a playlist's songs (often from many
                    // different albums) don't have.
                    for song in songs {
                        downloads.remove(songId: song.id.raw)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var moreButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {} label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistView(
            playlist: PlaylistSummary(
                id: "1", name: "Road Trip", comment: nil, owner: "ivan",
                public: true, songCount: 24, duration: 5400, created: nil, changed: nil, coverArt: nil
            )
        )
    }
}
