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
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInPlaylists) private var showUnavailableInPlaylists = true

    @State private var songs: [Child] = []
    @State private var isLoadingSongs = true
    @State private var loadError: String?

    @State private var backgroundColor: Color
    /// Cached `backgroundColor.darkened()` — see `AlbumView.darkenedBackgroundColor`'s identical
    /// doc comment for why: recomputed only at the two points `backgroundColor` itself changes,
    /// rather than on every row of every re-render.
    @State private var darkenedBackgroundColor: Color

    /// See `AlbumView.artworkURL`'s doc comment — computed synchronously in `init` for the same
    /// reason: a real URL ready at first render lets an already-cached cover (e.g. from
    /// `PlaylistCardView`, which requests this same URL) appear immediately with no placeholder
    /// flash.
    @State private var artworkURL: URL?

    @State private var showingRemoveDownloadConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAddToPlaylist = false
    @State private var isRefreshing = false
    @State private var isDeleting = false
    /// What went wrong adding the playlist's songs to another playlist, or deleting this one.
    @State private var addToPlaylistError: String?
    @State private var deleteError: String?
    /// The playlist as the server last said it is, after "Refresh" — its song count, length and
    /// changed time replace the ones of the `playlist` this screen was opened with.
    @State private var refreshedPlaylist: PlaylistSummary?
    /// "Remove from playlist" is on its way to the server — a second one waits for it, since each
    /// is a position in the list the first one is changing.
    @State private var isRemovingSong = false
    @State private var removeError: String?
    /// What this screen's removals have taken off the `playlist` it was opened with, whose song
    /// count, length and changed time are from before them.
    @State private var removedSongCount = 0
    @State private var removedDuration = 0
    @State private var changedAfterRemoval: Date?
    /// Where the user last was in the song list, to warm around on resume — see `onAppResume`.
    @State private var lastSeen = LastSeenIndex()

    /// Point size artwork renders at in a song row — mirrors `SongsListView.rowArtworkSize`.
    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.song

    /// `init` runs for every `PlaylistView(...)` a list constructs — one per realized row/card,
    /// on every parent re-render — and `darkened()` goes through `UIColor`'s HSB bridge, so the
    /// placeholder is computed once here instead of per init.
    private static let placeholderDarkenedBackground = Color(.systemBackground).darkened()

    init(playlist: PlaylistSummary, zoomNamespace: Namespace.ID? = nil) {
        self.playlist = playlist
        self.zoomNamespace = zoomNamespace
        _backgroundColor = State(initialValue: Color(.systemBackground))
        _darkenedBackgroundColor = State(initialValue: Self.placeholderDarkenedBackground)
        _artworkURL = State(initialValue: ArtworkRequest.playlistHeader(playlist.coverArt ?? playlist.id.raw).url)
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
        .onAppResume { warmAround(lastSeen.index, in: visibleSongs) }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddAlbumToPlaylistSheet(songs: songs) { songsToAdd, target in
                addToPlaylist(songsToAdd, target)
            }
        }
        .alert("Couldn't add the songs to the playlist", isPresented: Binding(
            get: { addToPlaylistError != nil },
            set: { if !$0 { addToPlaylistError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addToPlaylistError ?? "")
        }
        .alert("Couldn't delete the playlist", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Couldn't remove the song from the playlist", isPresented: Binding(
            get: { removeError != nil },
            set: { if !$0 { removeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
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
            .listRowBackground(darkenedBackgroundColor)

            trackListSection()

            playlistFooter()
                .listRowSeparator(.hidden)
                .listRowBackground(darkenedBackgroundColor)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 16, trailing: 16))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(darkenedBackgroundColor.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .toolbar {
            downloadButton
            moreButton
        }
        .tint(.primary)
    }

    /// Stale-while-revalidate: shows this playlist's cached songs immediately (no spinner) if
    /// any are cached, then revalidates against the server and only touches the displayed list if
    /// the fresh result actually differs from what's shown. Fetching, comparing and caching happen
    /// in `LibraryLoader`, off the main actor.
    private func loadSongs() async {
        for await event in LibraryLoader.load(.playlistSongs(playlistId: playlist.id.raw), shown: songs) {
            switch event {
            case .cached(let cached):
                songs = cached
                isLoadingSongs = false
            case .fresh(let entries):
                isLoadingSongs = false
                loadError = nil
                songs = entries
            case .upToDate:
                isLoadingSongs = false
                loadError = nil
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if there's
                // truly nothing to show.
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
                .listRowBackground(darkenedBackgroundColor)
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(darkenedBackgroundColor)
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
        let numbered = numberedSongs
        guard !networkMonitor.isOnline, !showUnavailableInPlaylists else { return numbered }
        return numbered.filter { downloads.isDownloaded($0.id.raw) }
    }

    /// `songs` with each repeat of a song numbered — see `Child.occurrence`. A playlist can hold
    /// one song several times; the numbering is what lets a row, and the queue entry played from
    /// it, be told from its repeats. Counted over the whole playlist before anything is hidden, so
    /// a row keeps its number whatever's filtered out. `songs` itself stays as loaded, so
    /// `LibraryLoader` still compares it against what the server sent.
    private var numberedSongs: [Child] {
        var seen: [FlexibleID: Int] = [:]
        return songs.map { song in
            let occurrence = seen[song.id, default: 0]
            seen[song.id] = occurrence + 1
            var numbered = song
            numbered.occurrence = occurrence
            return numbered
        }
    }

    func trackList() -> some View {
        // Hoisted rather than reading the `visibleSongs` computed property (which filters the
        // whole `songs` array) again below for the row-count checks — see
        // `AlbumView.trackList()`'s identical comment.
        let visibleSongs = self.visibleSongs
        return ForEach(Array(visibleSongs.enumerated()), id: \.element.instanceID) { index, track in
            Button {
                playTrack(at: index)
            } label: {
                SongRow(
                    track: track, rowArtworkSize: rowArtworkSize, displayScale: displayScale,
                    playlistId: playlist.id.raw,
                    onRemoveFromPlaylist: { removeFromPlaylist(track) },
                    showsGoToActions: true
                )
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
            .onAppear {
                lastSeen.index = index
                warmAround(index, in: visibleSongs)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(darkenedBackgroundColor)
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

    /// Warms the song thumbnails around `index` — a song row appeared, or the app resumed.
    private func warmAround(_ index: Int, in songs: [Child]) {
        let scale = displayScale
        let requests = ImageWarmer.neighbors(of: index, in: songs, count: ImageWarmer.scrollAheadCount)
            .map { ArtworkRequest.songRow(ArtworkRequest.artworkId(of: $0), scale: scale) }
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests, source: "playlist.songs") }
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
        let numbered = numberedSongs
        return networkMonitor.isOnline ? numbered : numbered.filter { downloads.isDownloaded($0.id.raw) }
    }

    private func playTrack(at index: Int) {
        let visible = visibleSongs
        guard visible.indices.contains(index) else { return }
        let queue = playableSongs
        // By `instanceID`, not `id`: with a song repeated in the playlist, the first repeat's
        // position would be found for a tap on any of them.
        guard let startAt = queue.firstIndex(where: { $0.instanceID == visible[index].instanceID }) else { return }
        player.play(queue: queue, startAt: startAt, fromPlaylist: true, sourceName: playlist.name, origin: .playlist(playlist.id.raw))
    }

    /// Takes `song` — this row's instance of it, if the playlist holds it more than once — out of
    /// the playlist. The row goes once the server has taken it out, not before.
    private func removeFromPlaylist(_ song: Child) {
        guard !isRemovingSong else { return }
        isRemovingSong = true
        Task {
            defer { isRemovingSong = false }
            do {
                let removal = try await PlaylistEditor.remove(song, from: playlist)
                songs = removal.songs
                if removal.removed {
                    player.playlistSongRemoved(songId: song.id, occurrence: song.occurrence ?? 0, fromPlaylist: playlist.id.raw)
                    removedSongCount += 1
                    removedDuration += song.duration ?? 0
                    changedAfterRemoval = Date()
                }
            } catch {
                removeError = error.localizedDescription
            }
        }
    }

    /// Adds to the end of the playlist, after the sheet has closed — so a failure (offline, say) is
    /// reported here.
    private func addToPlaylist(_ songsToAdd: [Child], _ target: PlaylistSummary) {
        Task {
            do {
                try await PlaylistEditor.add(songsToAdd, to: target)
            } catch {
                addToPlaylistError = error.localizedDescription
            }
        }
    }

    /// Replaces what this screen and the caches hold for the playlist with a fresh copy from the
    /// server — its songs, and the artwork of the playlist and its songs. Fetches *first* and only
    /// touches anything on success, like `AlbumView.refreshAlbum`. Unlike an album's, it leaves
    /// downloads alone: a playlist's songs are the albums' own, which have their own "Refresh".
    private func refreshPlaylist() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let fresh = try? await PlaylistEditor.refresh(playlist) else { return }
        let freshSongs = fresh.entry ?? []

        // Ids from both the old and new copy, in case a cover changed server-side.
        var artworkIds: Set<String> = [playlist.coverArt ?? playlist.id.raw, fresh.coverArt ?? playlist.id.raw]
        for song in songs + freshSongs { artworkIds.insert(ArtworkRequest.artworkId(of: song)) }
        // Full size, plus the row-thumbnail sizes song rows and playlist rows request.
        let pixelSizes: [Int?] = [
            nil,
            ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.song, scale: displayScale),
            ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.playlist, scale: displayScale),
        ]
        let artworkURLs = artworkIds.flatMap { id in
            pixelSizes.compactMap { try? client.coverArtURL(forId: id, size: $0) }
        }
        await Task.detached(priority: .userInitiated) {
            for url in artworkURLs { ImageCache.shared.remove(url) }
        }.value

        songs = freshSongs
        isLoadingSongs = false
        loadError = nil
        refreshedPlaylist = PlaylistSummary(
            id: fresh.id, name: fresh.name, comment: fresh.comment, owner: fresh.owner,
            public: fresh.public, songCount: fresh.songCount, duration: fresh.duration,
            created: fresh.created, changed: fresh.changed, coverArt: fresh.coverArt
        )
        removedSongCount = 0
        removedDuration = 0
        changedAfterRemoval = nil
        // A newly signed URL is what makes `CachedAsyncImage` reload; its stable cache key was just
        // purged, so this refetches the header artwork from the server.
        artworkURL = try? client.coverArtURL(forId: fresh.coverArt ?? playlist.coverArt ?? playlist.id.raw)
        await DownloadedArtwork.shared.requestSync()
    }

    /// Deletes the playlist on the server, then leaves its screen.
    private func deletePlaylist() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await PlaylistEditor.delete(playlist)
                dismiss()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func shuffle() {
        let queue = playableSongs
        guard !queue.isEmpty else { return }
        player.play(queue: queue.shuffled(), startAt: 0, fromPlaylist: true, sourceName: playlist.name, origin: .playlist(playlist.id.raw))
    }

    private var trackCountAndDuration: String {
        let summary = refreshedPlaylist ?? playlist
        let totalMinutes = max(0, summary.duration - removedDuration) / 60
        let songsText = String(localized: "\(max(0, summary.songCount - removedSongCount)) songs")
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
        CachedAsyncImage(url: artworkURL, fallbackMaxPixelSize: ImageCache.cardMaxPixelSize, onLoad: { uiImage in
            Task.detached(priority: .userInitiated) {
                guard let color = uiImage.averageColor() else { return }
                await MainActor.run {
                    backgroundColor = color
                    darkenedBackgroundColor = color.darkened()
                }
            }
        }) { image in
            image
                .resizable()
                .scaledToFit()
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
        if let changedAfterRemoval { return changedAfterRemoval }
        guard let changed = (refreshedPlaylist ?? playlist).changed else { return nil }
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
                .foregroundStyle(darkenedBackgroundColor)
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
            // Once per evaluation, not once per use: it's a scan of every song in the playlist.
            let isDownloaded = isPlaylistDownloaded
            Button {
                if isDownloaded {
                    showingRemoveDownloadConfirmation = true
                } else {
                    downloads.downloadAlbum(songs)
                }
            } label: {
                Image(systemName: isDownloaded ? "checkmark" : "arrow.down")
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
            Menu {
                Button {
                    showingAddToPlaylist = true
                } label: {
                    Label("Add to playlist", systemImage: "text.badge.plus")
                }
                .disabled(songs.isEmpty)

                Button {
                    Task { await refreshPlaylist() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || !networkMonitor.isOnline)

                if isPlaylistDownloaded {
                    Button(role: .destructive) {
                        showingRemoveDownloadConfirmation = true
                    } label: {
                        Label { Text("Remove Download") } icon: { redMenuSymbol("checkmark.circle.fill") }
                    }
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label { Text("Delete playlist") } icon: { redMenuSymbol("trash") }
                }
                .disabled(isDeleting || !networkMonitor.isOnline)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
            }
            .confirmationDialog(
                "Delete the playlist?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deletePlaylist() }
            } message: {
                Text("It will be deleted from your server for good.")
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
