//
//  HomeView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

/// The albums behind each of the Home carousels, derived from the whole library in one pass.
private struct HomeAlbumSections: Equatable, Sendable {
    var random: [AlbumID3] = []
    var latestReleases: [AlbumID3] = []
    var recentlyAdded: [AlbumID3] = []
    var favoriteArtists: [AlbumID3] = []

    static let carouselLimit = 20

    /// `starredArtistIds` empty means "none starred (or not loaded yet)".
    static func make(from albums: [AlbumID3], starredArtistIds: Set<String>, groupVersions: Bool) -> HomeAlbumSections {
        let limit = carouselLimit
        // "Group release versions" applies to every carousel except "Recently added", where a
        // newly added edition is exactly what the user wants to see.
        let candidates = groupVersions ? albums.groupedByPreferredVersion() : albums
        // The full release date when the tag has one, else just the year; albums with neither are
        // left out of "Latest releases" rather than sorted to an arbitrary end.
        func releaseKey(_ album: AlbumID3) -> Int? {
            if let date = album.releaseDate, let year = date.year {
                return year * 10_000 + (date.month ?? 0) * 100 + (date.day ?? 0)
            }
            return album.year.map { $0 * 10_000 }
        }
        let latest = candidates.compactMap { album in releaseKey(album).map { (album, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
        // `created` is an ISO-8601 timestamp, which sorts correctly as a string.
        let added = albums.filter { $0.created != nil }
            .sorted { ($0.created ?? "") > ($1.created ?? "") }
            .prefix(limit)
        let favorites = candidates.filter { $0.artistId.map { starredArtistIds.contains($0.raw) } ?? false }
            .shuffled().prefix(limit)
        return HomeAlbumSections(
            random: Array(candidates.shuffled().prefix(limit)),
            latestReleases: Array(latest),
            recentlyAdded: Array(added),
            favoriteArtists: Array(favorites)
        )
    }
}

/// One album carousel. Each carousel owns its zoom namespace: the same album can appear in
/// several carousels at once, and a namespace shared between them would make the album screen
/// zoom out of whichever card is highest on screen instead of the one that was tapped.
private struct HomeAlbumCarousel: View {
    let title: LocalizedStringKey
    let albums: [AlbumID3]

    @Namespace private var zoomNamespace
    /// The last tapped card, drawn above its neighbors so the zoom transition isn't covered by them.
    @State private var raisedAlbum: FlexibleID?
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(destination: LazyDestination { AlbumView(album: album, zoomNamespace: zoomNamespace) }) {
                                AlbumCardView(album: album, zoomNamespace: zoomNamespace)
                                    .frame(width: 160)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { raisedAlbum = album.id })
                            .zIndex(raisedAlbum == album.id ? 1 : 0)
                            .disabled(!(networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw)))
                            .onAppear { warmAhead(after: album) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                // The zoom transition's source is a card inside this scroll view; with clipping on,
                // the artwork is cut off at the scroll view's bounds while it flies in and out.
                .scrollClipDisabled()
            }
        }
    }

    private func warmAhead(after album: AlbumID3) {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        let requests = albums[(index + 1)...].prefix(ImageWarmer.scrollAheadCount)
            .map { ArtworkRequest.albumCard($0.coverArt ?? $0.id.raw) }
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests) }
    }
}

struct HomeView: View {
    @Bindable private var navigation = AppNavigation.shared

    private let client = SubsonicClient.shared

    @Namespace private var zoomNamespace

    @State private var isConnected = SubsonicClient.shared.isConfigured
    @State private var allAlbums: [AlbumID3] = []
    @State private var sections = HomeAlbumSections()
    @State private var starredArtistIds: Set<String> = []
    /// The starred artists the favorite-artists carousel was last picked for.
    @State private var favoritesBuiltFor: Set<String>?
    @State private var recentlyPlayed: [AlbumID3] = []
    @State private var topPlaylists: [PlaylistSummary] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @AppStorage(HomeContentSettings.Keys.order) private var carouselOrderStorage = ""
    @AppStorage(HomeContentSettings.Keys.disabled) private var disabledCarouselsStorage = ""

    private var visibleCarousels: [HomeCarouselKind] {
        HomeContentSettings.visible(order: carouselOrderStorage, disabled: disabledCarouselsStorage)
    }

    @ViewBuilder
    private func carousel(for kind: HomeCarouselKind) -> some View {
        switch kind {
        case .randomAlbums: albumCarousel(kind.title, albums: sections.random)
        case .latestReleases: albumCarousel(kind.title, albums: sections.latestReleases)
        case .recentlyAdded: albumCarousel(kind.title, albums: sections.recentlyAdded)
        case .recentlyPlayed: albumCarousel(kind.title, albums: recentlyPlayed)
        case .favoriteArtistAlbums: albumCarousel(kind.title, albums: sections.favoriteArtists)
        case .topPlaylists: playlistCarousel(kind.title, playlists: topPlaylists)
        }
    }

    var body: some View {
        NavigationStack(path: $navigation.paths[AppNavigation.homeTab]) {
            ScrollView {
                if !isConnected {
                    Text("Connect to your Navidrome server to get started")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                        .padding(.top, 120)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(visibleCarousels) { kind in
                            carousel(for: kind)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Home")
            .appRouteDestinations()
            .toolbar {
                moreButton
                settingsButton
            }
            .task { await refresh() }
            .onChange(of: groupReleaseVersionsEnabled) {
                Task { await rebuildSections(reshuffle: true) }
            }
        }
    }

    // MARK: Carousels

    private func albumCarousel(_ title: LocalizedStringKey, albums: [AlbumID3]) -> some View {
        HomeAlbumCarousel(title: title, albums: albums)
    }

    @ViewBuilder
    private func playlistCarousel(_ title: LocalizedStringKey, playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            carousel(title) {
                ForEach(playlists) { playlist in
                    NavigationLink(destination: LazyDestination { PlaylistView(playlist: playlist, zoomNamespace: zoomNamespace) }) {
                        PlaylistCardView(playlist: playlist, zoomNamespace: zoomNamespace)
                            .frame(width: 160)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable(playlist))
                }
            }
        }
    }

    /// Same carousel presentation as `ArtistAlbumsView.albumCarousel`.
    private func carousel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so only the cards scrolled into view build and start loading artwork.
                LazyHStack(alignment: .top, spacing: 16) {
                    content()
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private func isAvailable(_ playlist: PlaylistSummary) -> Bool {
        guard !networkMonitor.isOnline else { return true }
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return songIds.contains { downloads.isDownloaded($0) }
    }

    // MARK: Loading

    /// Runs from `.task` every time the tab becomes visible. Only the first load shows the
    /// spinner; later runs refresh each section quietly. The four library-derived carousels share
    /// one `allAlbums` load (cached, scan-gated), and the others load alongside it.
    private func refresh() async {
        isConnected = client.isConfigured
        guard isConnected else { return }
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        async let starred: Void = loadStarredArtists()
        async let played: Void = loadRecentlyPlayed()
        async let playlists: Void = loadTopPlaylists()
        await loadLibrary()
        _ = await (starred, played, playlists)
        // The favorite-artist carousel needs both the library and the starred set.
        await rebuildSections(reshuffle: false)
    }

    private func loadLibrary() async {
        for await event in LibraryLoader.load(.allAlbums(), shown: allAlbums) {
            switch event {
            case .cached(let albums), .fresh(let albums):
                allAlbums = albums
                await rebuildSections(reshuffle: true)
            case .upToDate, .failed:
                break
            }
        }
    }

    /// `reshuffle` re-rolls the random picks; otherwise they stay put so a quiet refresh (popping
    /// back to Home) doesn't swap the cards under the user.
    private func rebuildSections(reshuffle: Bool) async {
        let albums = allAlbums
        let starredIds = starredArtistIds
        let groupVersions = groupReleaseVersionsEnabled
        defer { favoritesBuiltFor = starredIds }
        let built = await Task.detached(priority: .userInitiated) {
            HomeAlbumSections.make(from: albums, starredArtistIds: starredIds, groupVersions: groupVersions)
        }.value
        if reshuffle || sections.random.isEmpty {
            sections = built
        } else {
            sections.latestReleases = built.latestReleases
            sections.recentlyAdded = built.recentlyAdded
            // Random like "Random albums": only re-rolled when the starred artists change.
            if starredIds != favoritesBuiltFor || sections.favoriteArtists.isEmpty {
                sections.favoriteArtists = built.favoriteArtists
            }
        }
    }

    private func loadStarredArtists() async {
        guard visibleCarousels.contains(.favoriteArtistAlbums) else { return }
        guard let starred = try? await client.getStarred2() else { return }
        starredArtistIds = Set((starred.artist ?? []).map { $0.id.raw })
    }

    private func loadRecentlyPlayed() async {
        guard visibleCarousels.contains(.recentlyPlayed) else { return }
        for await event in LibraryLoader.load(.recentAlbums(), shown: recentlyPlayed) {
            switch event {
            case .cached(let albums), .fresh(let albums):
                recentlyPlayed = albums
            case .upToDate, .failed:
                break
            }
        }
    }

    /// Subsonic exposes no play count for playlists, so a playlist's count is the sum of its
    /// songs' play counts, fetched per playlist.
    private func loadTopPlaylists() async {
        guard visibleCarousels.contains(.topPlaylists) else { return }
        var playlists: [PlaylistSummary] = []
        for await event in LibraryLoader.load(.allPlaylists(), shown: nil) {
            switch event {
            case .cached(let cached), .fresh(let cached):
                playlists = cached
            case .upToDate, .failed:
                break
            }
        }
        guard !playlists.isEmpty else { return }
        let client = client
        let counts = await withTaskGroup(of: (String, Int).self) { group -> [String: Int] in
            for playlist in playlists {
                group.addTask {
                    let songs = (try? await client.getPlaylist(id: playlist.id.raw))?.entry ?? []
                    return (playlist.id.raw, songs.reduce(0) { $0 + ($1.playCount ?? 0) })
                }
            }
            var result: [String: Int] = [:]
            for await (id, count) in group { result[id] = count }
            return result
        }
        topPlaylists = playlists
            .filter { (counts[$0.id.raw] ?? 0) > 0 }
            .sorted { (counts[$0.id.raw] ?? 0) > (counts[$1.id.raw] ?? 0) }
            .prefix(HomeAlbumSections.carouselLimit)
            .map { $0 }
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
    
    @ToolbarContentBuilder
        private var settingsButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.primary)
                }
            }
        }
}

#Preview {
    HomeView()
}
