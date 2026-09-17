import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var albumZoomNamespace

    private let client = SubsonicClient.shared

    @State private var isConnected = SubsonicClient.shared.isConfigured
    @State private var recentAlbums: [AlbumID3] = []
    @State private var isLoadingAlbums = false
    @State private var isFetchingAlbums = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
            NavigationStack {
                ScrollView {
                    if isConnected {
                        libraryContent
                    } else {
                        disconnectedContent
                    }
                }
                .environment(\.colorScheme, colorScheme)
                .navigationTitle("Library")
                .toolbar {
                    plusButton
                    settingsButton
                }
                .onAppear {
                    refresh()
                }
            }
            .environment(\.colorScheme, colorScheme)
        }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: Navigation Rows
            VStack(spacing: 0) {
                LibraryNavigationRow(title: "Playlists", icon: "music.note.list") {
                    PlaylistsListView()
                }
                rowDivider
                LibraryNavigationRow(title: "Artists", icon: "music.mic") {
                    ArtistsListView()
                }
                rowDivider
                LibraryNavigationRow(title: "Albums", icon: "square.stack") {
                    AlbumsListView()
                }
                rowDivider
                LibraryNavigationRow(title: "Songs", icon: "music.note") {
                    SongsListView()
                }
            }
            .padding(.horizontal, 16)

            Text("Recently played")
                .font(.system(size: 20))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 18)

            recentAlbumsGrid
        }
        .padding(.top, 8)
    }

    private var disconnectedContent: some View {
        VStack(spacing: 16) {
            Text("Connect to your Navidrome server to get started")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            NavigationLink(destination: ServerSettingsView()) {
                Text("Connect")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    /// Called from `.onAppear`, which fires every time this screen becomes visible again —
    /// including when popping back from a pushed album. Only the very first load shows the
    /// spinner and replaces the grid; later calls refetch quietly in the background and just
    /// update `recentAlbums` in place once done, so the grid's view identity (and the
    /// ScrollView's scroll position) stays stable instead of being torn down and rebuilt,
    /// which was also breaking the album's zoom-dismiss transition mid-animation.
    private func refresh() {
        isConnected = client.isConfigured
        guard client.isConfigured else {
            recentAlbums = []
            hasLoadedOnce = false
            return
        }
        guard !isFetchingAlbums else { return }
        isFetchingAlbums = true

        if !hasLoadedOnce {
            isLoadingAlbums = true
        }
        Task {
            do {
                let albums = try await client.getAlbumList2(type: .recent, size: 30)
                await MainActor.run {
                    recentAlbums = albums
                    loadError = nil
                    isLoadingAlbums = false
                    isFetchingAlbums = false
                    hasLoadedOnce = true
                }
                // Kick off every album's artwork now, before the user has even looked at the
                // grid, instead of waiting for each card to scroll into view and start its own
                // fetch — by the time anything is tapped, ImageCache should already have it.
                prefetchArtwork(for: albums)
                Task { await LibraryCacheDatabase.shared.cacheRecentAlbums(albums) }
            } catch {
                // Offline, or the request otherwise failed — fall back to whatever was cached
                // the last time this grid loaded successfully, if ever.
                if let cached = await LibraryCacheDatabase.shared.cachedRecentAlbums() {
                    await MainActor.run {
                        recentAlbums = cached
                        loadError = nil
                        isLoadingAlbums = false
                        isFetchingAlbums = false
                        hasLoadedOnce = true
                    }
                    prefetchArtwork(for: cached)
                    return
                }
                await MainActor.run {
                    if !hasLoadedOnce {
                        loadError = error.localizedDescription
                    }
                    isLoadingAlbums = false
                    isFetchingAlbums = false
                }
            }
        }
    }

    private func prefetchArtwork(for albums: [AlbumID3]) {
        for album in albums {
            ImageCache.shared.prefetch(try? client.coverArtURL(forId: album.coverArt ?? album.id.raw))
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 40)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    @ViewBuilder
    private var recentAlbumsGrid: some View {
        if isLoadingAlbums {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else if recentAlbums.isEmpty {
            Text("No recently played albums yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(recentAlbums) { album in
                    NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                        AlbumCardView(album: album, zoomNamespace: albumZoomNamespace)
                    }
                    .buttonStyle(.plain)
                    .disabled(!(networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    struct LibraryNavigationRow<Destination: View>: View {
        let title: LocalizedStringKey
        let icon: String
        @ViewBuilder let destination: () -> Destination

        var body: some View {
            NavigationLink(destination: destination) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 24, alignment: .center)

                    Text(title)
                        .font(.title3)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ToolbarContentBuilder
        private var plusButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                }
            }
        }

    @ToolbarContentBuilder
        private var settingsButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(destination: ServerSettingsView()) {
                        Label("Server", systemImage: "server.rack")
                    }
                    NavigationLink(destination: PlaybackSettingsView()) {
                        Label("Playback", systemImage: "play.circle")
                    }
                    NavigationLink(destination: DownloadsSettingsView()) {
                        Label("Downloads", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.primary)
                }
            }
        }
}

#Preview {
    LibraryView()
}
