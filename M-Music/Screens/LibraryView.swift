import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var albumZoomNamespace

    private let client = SubsonicClient.shared

    @State private var isConnected = SubsonicClient.shared.isConfigured
    @State private var recentAlbums: [AlbumID3] = []
    @State private var isLoadingAlbums = false
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
                .task { await refresh() }
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

            NavigationLink {
                ServerSettingsView()
            } label: {
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

    /// Runs from `.task`, which starts every time this screen becomes visible again — including
    /// when popping back from a pushed album. Only the very first load shows the spinner and
    /// replaces the grid; later runs refetch quietly and just update `recentAlbums` in place once
    /// done, so the grid's view identity (and the ScrollView's scroll position) stays stable
    /// instead of being torn down and rebuilt, which was also breaking the album's zoom-dismiss
    /// transition mid-animation.
    ///
    /// Stale-while-revalidate: shows cached recent albums immediately (no spinner) if any are
    /// cached, then revalidates against the server and only touches the displayed grid if the
    /// fresh result actually differs from what's shown. Fetching, comparing and caching happen in
    /// `LibraryLoader`, off the main actor.
    private func refresh() async {
        isConnected = client.isConfigured
        guard client.isConfigured else {
            recentAlbums = []
            hasLoadedOnce = false
            return
        }
        if !hasLoadedOnce {
            isLoadingAlbums = true
        }
        defer { isLoadingAlbums = false }
        for await event in LibraryLoader.load(.recentAlbums(), shown: recentAlbums) {
            switch event {
            case .cached(let cached):
                recentAlbums = cached
                hasLoadedOnce = true
                isLoadingAlbums = false
                prefetchArtwork(for: cached)
            case .fresh(let albums):
                loadError = nil
                isLoadingAlbums = false
                hasLoadedOnce = true
                recentAlbums = albums
                // Kick off every album's artwork now, before the user has even looked at the
                // grid, instead of waiting for each card to scroll into view and start its
                // own fetch — by the time anything is tapped, ImageCache should already have it.
                prefetchArtwork(for: albums)
            case .upToDate:
                loadError = nil
                isLoadingAlbums = false
                hasLoadedOnce = true
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                isLoadingAlbums = false
                if recentAlbums.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    /// Downloads each album's original cover to disk (no decoding) so opening it from here
    /// doesn't wait on the network — `ImageCache` itself bounds how many run at once.
    private func prefetchArtwork(for albums: [AlbumID3]) {
        let urls = albums.compactMap { try? client.coverArtURL(forId: $0.coverArt ?? $0.id.raw) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { await ImageCache.shared.prefetchOriginalData(url) }
                }
            }
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
                    // Closure-based destinations: the `destination:` autoclosure form built all four
                    // settings screens' structs (`PlaybackSettingsView` alone has ~17 `@AppStorage`
                    // properties) every time this view's body ran; these only build on push.
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Label("Server", systemImage: "server.rack")
                    }
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("Playback", systemImage: "play.circle")
                    }
                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        Label("Downloads", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
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
