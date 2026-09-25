//
//  PlaylistsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct PlaylistsListView: View {
    @Namespace private var playlistZoomNamespace
    @Environment(\.displayScale) private var displayScale

    private let client = SubsonicClient.shared

    @State private var searchText = ""

    @State private var playlists: [PlaylistSummary] = []
    /// Cached result of filtering `playlists`, recomputed only by `updateDisplayedPlaylists()`
    /// rather than on every `body` evaluation — see `AlbumsListView.displayedAlbums`.
    @State private var displayedPlaylists: [PlaylistSummary] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    @AppStorage("library.playlistsDisplayStyle") private var displayStyleStorage = LibraryDisplayStyle.grid.storageKey
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInLists) private var showUnavailableInLists = true

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    private var displayStyle: LibraryDisplayStyle {
        LibraryDisplayStyle(storageKey: displayStyleStorage)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                } else if displayedPlaylists.isEmpty {
                    Text("No playlists found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch displayStyle {
                    case .grid:
                        ScrollView {
                            playlistsGrid
                        }
                    case .list:
                        playlistsList
                    }
                }
            }
            .refreshable { await performRefresh() }
            .navigationTitle("Playlists")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .task { await refresh() }
            .onAppear {
                // So playlists cached in an earlier session gray out correctly before any
                // playlist is opened this session — guarded internally, cheap to call again.
                Task(priority: .utility) { await LibraryCacheStatus.shared.preload() }
            }
            .onChange(of: searchText) { updateDisplayedPlaylists() }
            .onChange(of: showUnavailableInLists) { updateDisplayedPlaylists() }
            .onChange(of: networkMonitor.isOnline) { updateDisplayedPlaylists() }
            .onChange(of: downloads.revision) { updateDisplayedPlaylists() }
            .onChange(of: libraryCacheStatus.revision) { updateDisplayedPlaylists() }
        }
    }

    private var playlistsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(displayedPlaylists) { playlist in
                NavigationLink(destination: PlaylistView(playlist: playlist, zoomNamespace: playlistZoomNamespace)) {
                    PlaylistCardView(playlist: playlist, zoomNamespace: playlistZoomNamespace)
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable(playlist))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var playlistsList: some View {
        List {
            ForEach(displayedPlaylists) { playlist in
                NavigationLink(destination: PlaylistView(playlist: playlist, zoomNamespace: playlistZoomNamespace)) {
                    PlaylistRow(playlist: playlist, zoomNamespace: playlistZoomNamespace, displayScale: displayScale)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .disabled(!isAvailable(playlist))
            }
        }
        .listStyle(.plain)
    }

    /// Same expression `PlaylistCardView`/`PlaylistRow` compute internally for their own dimming
    /// — this is the only way to also `.disabled(...)` the `NavigationLink` they're the label of.
    private func isAvailable(_ playlist: PlaylistSummary) -> Bool {
        guard !networkMonitor.isOnline else { return true }
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return songIds.contains { downloads.isDownloaded($0) }
    }

    /// Stricter than `isAvailable(_:)` (which only needs one downloaded song) — used to decide
    /// whether to hide a playlist entirely when "Show unavailable in lists" is off, as opposed to
    /// just dimming it.
    private func isFullyDownloaded(_ playlist: PlaylistSummary) -> Bool {
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return !songIds.isEmpty && songIds.allSatisfy { downloads.isDownloaded($0) }
    }

    private func updateDisplayedPlaylists() {
        var result = playlists
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.owner?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        if !networkMonitor.isOnline, !showUnavailableInLists {
            result = result.filter { isFullyDownloaded($0) }
        }
        displayedPlaylists = result
    }

    /// Stale-while-revalidate: shows cached playlists immediately (no spinner) if any are cached,
    /// then revalidates against the server and only touches the displayed list if the fresh
    /// result actually differs from what's already shown. Loading, the "did anything change?"
    /// check and the cache write all happen in `LibraryLoader`, off the main actor; this only
    /// applies what it reports. Runs from `.task`, so leaving the screen cancels it.
    private func refresh() async {
        guard client.isConfigured else {
            playlists = []
            displayedPlaylists = []
            hasLoadedOnce = false
            return
        }
        // Only the very first load shows the spinner (and thus swaps out the list) — a quiet
        // reappearance (e.g. popping back from a pushed `PlaylistView`) must never briefly tear
        // down the list's identity, or it resets scroll position and breaks an in-flight
        // zoom-dismiss transition.
        if !hasLoadedOnce {
            isLoading = true
        }
        await performRefresh()
    }

    /// `force` skips the "has the server library changed?" check, for pull-to-refresh.
    private func performRefresh(force: Bool = false) async {
        guard client.isConfigured else { return }
        defer { isLoading = false }
        for await event in LibraryLoader.load(.allPlaylists(), shown: playlists, force: force) {
            switch event {
            case .cached(let cached):
                playlists = cached
                updateDisplayedPlaylists()
                hasLoadedOnce = true
                isLoading = false
            case .fresh(let fetched):
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
                playlists = fetched
                updateDisplayedPlaylists()
            case .upToDate:
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                isLoading = false
                if playlists.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

/// A single row for the "List"-style playlists browse — rounded-corner artwork on the leading
/// edge (mirrors `PlaylistCardView.artwork`, but fit rather than cropped to a square — see
/// `artwork` below), name/creator stacked next to it (mirrors `ArtistsListView.ArtistRow`, which
/// uses a circular artwork with just a title).
private struct PlaylistRow: View {
    let playlist: PlaylistSummary
    var zoomNamespace: Namespace.ID? = nil

    /// Computed once, in `init` — not via `.task` — so an already-cached cover (e.g. already
    /// fetched by this same row earlier) renders on the very first frame instead of flashing the
    /// placeholder. Mirrors `SongRow.artworkURL`'s doc comment.
    ///
    /// Requested downscaled to this row's own size (like `SongRow`), not the full original the
    /// grid card and `PlaylistView` both request — a screen full of list rows fetching and
    /// decoding full-size covers just to show them at `rowArtworkSize` is wasted bandwidth and
    /// memory. That does mean this doesn't share `PlaylistView`'s cache entry the way the grid
    /// card does — `.task` below separately prefetches the full-size cover in the background so
    /// opening `PlaylistView` from this row is still lag-free, without paying full-size decode
    /// cost for the row itself.
    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = 64
    private let artworkCornerRadius: CGFloat = 4

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    init(playlist: PlaylistSummary, zoomNamespace: Namespace.ID? = nil, displayScale: CGFloat) {
        self.playlist = playlist
        self.zoomNamespace = zoomNamespace
        let pixelSize = Int(rowArtworkSize * displayScale)
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: playlist.coverArt ?? playlist.id.raw, size: pixelSize))
    }

    var body: some View {
        HStack(spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 18))
                    .lineLimit(1)
                Text(playlist.owner ?? "Unknown Creator")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .dimmedIfUnavailable(isAvailable)
        // Full-size cover's bytes, prefetched to disk in the background (no decode — the row
        // itself only shows the small thumbnail) — see `artworkURL`'s doc comment. Keyed to
        // `playlist.id` so scrolling this row's cell to a different playlist (cell reuse)
        // cancels the stale prefetch and starts the right one.
        .task(id: playlist.id) {
            await ImageCache.shared.prefetchOriginalData(try? SubsonicClient.shared.coverArtURL(forId: playlist.coverArt ?? playlist.id.raw))
        }
    }

    /// See `PlaylistCardView.isAvailable`'s doc comment — same check, same reasoning.
    private var isAvailable: Bool {
        guard !networkMonitor.isOnline else { return true }
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return songIds.contains { downloads.isDownloaded($0) }
    }

    @ViewBuilder
    private var artwork: some View {
        // `.fit`, not `.fill` — a non-square cover keeps its own aspect ratio (its longer side
        // matching `rowArtworkSize`) instead of being cropped to fill a square, and the rounded
        // corners/outline below clip and trace its own resulting bounds rather than a fixed
        // square container.
        let image = CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: artworkCornerRadius)
                        .stroke(Color.secondary, lineWidth: 0.15)
                )
        } placeholder: {
            RoundedRectangle(cornerRadius: artworkCornerRadius)
                .fill(Color.secondary.opacity(0.1))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: rowArtworkSize, height: rowArtworkSize)

        if let zoomNamespace {
            image.matchedTransitionSource(id: playlist.id, in: zoomNamespace)
        } else {
            image
        }
    }
}

#Preview {
    PlaylistsListView()
}
