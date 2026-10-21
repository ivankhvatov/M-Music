//
//  HomeView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

/// The albums behind each of the Home carousels, derived from the whole library in one pass.
struct HomeAlbumSections: Equatable, Sendable {
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
    /// Names this carousel's look-ahead queue in `ImageWarmer`, so carousels don't cancel each other's.
    let source: String

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
        Task { await ImageWarmer.shared.warmAhead(requests, source: source) }
    }
}

/// A Top playlists card with its link. It owns the observation of what decides whether the
/// playlist is available offline, so a download or library-cache change re-renders the cards
/// rather than all of Home.
private struct HomePlaylistCell: View {
    let playlist: PlaylistSummary
    let zoomNamespace: Namespace.ID
    let onAppear: () -> Void

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        NavigationLink(destination: LazyDestination { PlaylistView(playlist: playlist, zoomNamespace: zoomNamespace) }) {
            PlaylistCardView(playlist: playlist, zoomNamespace: zoomNamespace)
                .frame(width: 160)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onAppear(perform: onAppear)
    }

    private var isAvailable: Bool {
        guard !networkMonitor.isOnline else { return true }
        let songIds = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw) ?? []
        return songIds.contains { downloads.isDownloaded($0) }
    }
}

/// What Home needs on its first frame, and when its slower parts are worth repeating.
enum HomeLoadingPolicy {
    /// How many cards of each carousel are on the first screen, about.
    static let cardsPerCarousel = 3

    /// The images of the first few cards of each carousel, in the order the carousels are shown
    /// (empty ones skipped), up to `limit` — what `ImageReadiness` waits for before Home shows.
    static func firstScreenRequests(
        carousels: [HomeCarouselKind],
        albums: (HomeCarouselKind) -> [AlbumID3],
        playlists: [PlaylistSummary],
        perCarousel: Int = cardsPerCarousel,
        limit: Int = ImageWarmer.gateLimit
    ) -> [ArtworkRequest] {
        var requests: [ArtworkRequest] = []
        for kind in carousels {
            if kind == .topPlaylists {
                requests += playlists.prefix(perCarousel).map { .playlistCard($0.coverArt ?? $0.id.raw) }
            } else {
                requests += albums(kind).prefix(perCarousel).map { .albumCard($0.coverArt ?? $0.id.raw) }
            }
            if requests.count >= limit { break }
        }
        return Array(requests.prefix(limit))
    }

    /// The expensive requests — the starred artists and, above all, the per-playlist play counts —
    /// aren't repeated every time the tab is visited again: only if they've never run, or not for
    /// `interval`.
    static func shouldRunExpensiveRefresh(last: Date?, now: Date = Date(), interval: TimeInterval = 300) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Top playlists: the ones with any plays, most played first, at most `limit`.
    static func rank(_ playlists: [PlaylistSummary], playCounts: [String: Int], limit: Int) -> [PlaylistSummary] {
        Array(
            playlists
                .filter { (playCounts[$0.id.raw] ?? 0) > 0 }
                .sorted { (playCounts[$0.id.raw] ?? 0) > (playCounts[$1.id.raw] ?? 0) }
                .prefix(limit)
        )
    }

    /// The part of the screen whose data decides what's on the first frame.
    enum Part: Hashable { case library, recentlyPlayed, topPlaylists }

    /// Which parts the first frame waits for, given the carousels that are switched on.
    static func parts(for carousels: [HomeCarouselKind]) -> Set<Part> {
        var parts: Set<Part> = []
        for kind in carousels {
            switch kind {
            case .randomAlbums, .latestReleases, .recentlyAdded, .favoriteArtistAlbums: parts.insert(.library)
            case .recentlyPlayed: parts.insert(.recentlyPlayed)
            case .topPlaylists: parts.insert(.topPlaylists)
            }
        }
        return parts
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
    /// Keeps the carousels hidden on first open until the first cards' images are in memory.
    @State private var imageReadiness = ImageReadiness()
    /// Builds the library-derived carousels off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()
    /// The parts the first frame is still waiting for (see `settle`).
    @State private var pendingParts: Set<HomeLoadingPolicy.Part> = []
    /// When the expensive requests last ran — see `HomeLoadingPolicy.shouldRunExpensiveRefresh`.
    @State private var lastExpensiveRefresh: Date?
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false

    @AppStorage(HomeContentSettings.Keys.order) private var carouselOrderStorage = ""
    @AppStorage(HomeContentSettings.Keys.disabled) private var disabledCarouselsStorage = ""

    private var visibleCarousels: [HomeCarouselKind] {
        HomeContentSettings.visible(order: carouselOrderStorage, disabled: disabledCarouselsStorage)
    }

    private func albums(for kind: HomeCarouselKind) -> [AlbumID3] {
        switch kind {
        case .randomAlbums: sections.random
        case .latestReleases: sections.latestReleases
        case .recentlyAdded: sections.recentlyAdded
        case .recentlyPlayed: recentlyPlayed
        case .favoriteArtistAlbums: sections.favoriteArtists
        case .topPlaylists: []
        }
    }

    @ViewBuilder
    private func carousel(for kind: HomeCarouselKind) -> some View {
        switch kind {
        case .topPlaylists: playlistCarousel(kind.title, playlists: topPlaylists)
        default: albumCarousel(kind, albums: albums(for: kind))
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
                } else if isLoading || !imageReadiness.isReady {
                    // Also while the first cards' images aren't in memory yet: hold the carousels
                    // back until they are (see `ImageReadiness`) rather than showing placeholders.
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
                rebuildSections(reshuffle: true)
            }
            .onChange(of: imageReadiness.isReady) { _, isReady in
                if isReady { warmAllCarousels() }
            }
        }
    }

    // MARK: Carousels

    private func albumCarousel(_ kind: HomeCarouselKind, albums: [AlbumID3]) -> some View {
        HomeAlbumCarousel(title: kind.title, albums: albums, source: "home.\(kind.rawValue)")
    }

    @ViewBuilder
    private func playlistCarousel(_ title: LocalizedStringKey, playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            carousel(title) {
                ForEach(playlists) { playlist in
                    HomePlaylistCell(playlist: playlist, zoomNamespace: zoomNamespace) {
                        warmAhead(after: playlist, in: playlists)
                    }
                }
            }
        }
    }

    /// A card scrolled into view: warm the ones after it in its carousel, so a fast swipe finds
    /// them ready.
    private func warmAhead(after playlist: PlaylistSummary, in playlists: [PlaylistSummary]) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let requests = playlists[(index + 1)...].prefix(ImageWarmer.scrollAheadCount)
            .map { ArtworkRequest.playlistCard($0.coverArt ?? $0.id.raw) }
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests, source: "home.topPlaylists") }
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

    // MARK: First frame

    private var firstScreenRequests: [ArtworkRequest] {
        HomeLoadingPolicy.firstScreenRequests(
            carousels: visibleCarousels,
            albums: { albums(for: $0) },
            playlists: topPlaylists
        )
    }

    /// One of the parts the first frame waits for has its data (or has nothing to give). When the
    /// last one does, the spinner goes and the images of the first cards are awaited instead.
    /// Everything that arrives later fills its carousel in without holding anything back.
    private func settle(_ part: HomeLoadingPolicy.Part) {
        guard pendingParts.remove(part) != nil, pendingParts.isEmpty else { return }
        isLoading = false
        imageReadiness.require(firstScreenRequests)
    }

    /// Warms the first cards of *every* carousel, not just the ones on the first screen the gate
    /// waits for, so scrolling down to a lower carousel finds its cards already decoded.
    private func warmAllCarousels() {
        let requests = HomeLoadingPolicy.firstScreenRequests(
            carousels: visibleCarousels, albums: { albums(for: $0) }, playlists: topPlaylists,
            perCarousel: 12, limit: 12 * HomeCarouselKind.allCases.count
        )
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests, source: "home") }
    }

    /// Tells `ImageWarmer` which covers Home opens with, to decode them ahead of the next resume.
    /// The random and favorite-artist picks change on every load, so only the carousels that stay
    /// the same are remembered.
    private func rememberFirstScreen() {
        if imageReadiness.isReady { warmAllCarousels() }
        let stable = visibleCarousels.filter { $0 != .randomAlbums && $0 != .favoriteArtistAlbums }
        let requests = HomeLoadingPolicy.firstScreenRequests(
            carousels: stable, albums: { albums(for: $0) }, playlists: topPlaylists,
            perCarousel: 4, limit: ImageWarmer.manifestLimit
        )
        Task { await ImageWarmer.shared.remember(.home, requests) }
    }

    // MARK: Loading

    /// Runs from `.task` every time the tab becomes visible. Only the first load shows the
    /// spinner — and only until the cached library, recently played and top playlists are in; the
    /// network revalidation then updates the carousels in place. The four library-derived
    /// carousels share one `allAlbums` load (cached, scan-gated), the others load alongside it,
    /// and the expensive requests aren't repeated on every visit.
    private func refresh() async {
        isConnected = client.isConfigured
        guard isConnected else { return }
        let runExpensive = HomeLoadingPolicy.shouldRunExpensiveRefresh(last: lastExpensiveRefresh)
        if !hasLoadedOnce {
            isLoading = true
            pendingParts = HomeLoadingPolicy.parts(for: visibleCarousels)
            if pendingParts.isEmpty { isLoading = false }
        }
        defer {
            // Whatever is still pending (offline with no cache, a failed load) must not keep the
            // spinner up — except the library while its carousels are still being built: that
            // build settles it itself, and the images to wait for aren't known before.
            for part in pendingParts where !(part == .library && deriver.isPending) { settle(part) }
            isLoading = false
            hasLoadedOnce = true
            if pendingParts.isEmpty, !deriver.isPending { imageReadiness.require(firstScreenRequests) }
            rememberFirstScreen()
        }

        async let starred: Void = loadStarredArtists(runExpensive: runExpensive)
        async let played: Void = loadRecentlyPlayed()
        async let playlists: Void = loadTopPlaylists(runExpensive: runExpensive)
        await loadLibrary()
        _ = await (starred, played, playlists)
        if runExpensive { lastExpensiveRefresh = Date() }
        // The favorite-artist carousel needs both the library and the starred set.
        rebuildSections(reshuffle: false)
    }

    private func loadLibrary() async {
        var gotAlbums = false
        for await event in LibraryLoader.load(.allAlbums(), shown: allAlbums) {
            switch event {
            case .cached(let albums), .fresh(let albums):
                gotAlbums = true
                allAlbums = albums
                rebuildSections(reshuffle: true)
            case .upToDate, .failed:
                break
            }
        }
        // Nothing came of it (no cache, offline): the first frame must not wait for it.
        if !gotAlbums { settle(.library) }
    }

    /// `reshuffle` re-rolls the random picks; otherwise they stay put so a quiet refresh (popping
    /// back to Home) doesn't swap the cards under the user. The sorting and shuffling of the whole
    /// library run off the main actor, and only the newest request is applied (`OffMainDeriver`).
    private func rebuildSections(reshuffle: Bool) {
        let albums = allAlbums
        let starredIds = starredArtistIds
        let groupVersions = groupReleaseVersionsEnabled
        deriver.run({
            HomeAlbumSections.make(from: albums, starredArtistIds: starredIds, groupVersions: groupVersions)
        }, apply: { built in
            var next = sections
            if reshuffle || sections.random.isEmpty {
                next = built
            } else {
                next.latestReleases = built.latestReleases
                next.recentlyAdded = built.recentlyAdded
                // Random like "Random albums": only re-rolled when the starred artists change.
                if starredIds != favoritesBuiltFor || sections.favoriteArtists.isEmpty {
                    next.favoriteArtists = built.favoriteArtists
                }
            }
            favoritesBuiltFor = starredIds
            // Only a change re-renders the carousels.
            if next != sections { sections = next }
            // Whichever build is applied last settles the library part, so a build superseded
            // by a newer one never leaves it pending.
            settle(.library)
            rememberFirstScreen()
        })
    }

    private func loadStarredArtists(runExpensive: Bool) async {
        guard runExpensive, visibleCarousels.contains(.favoriteArtistAlbums) else { return }
        guard let starred = try? await client.getStarred2() else { return }
        let ids = Set((starred.artist ?? []).map { $0.id.raw })
        if ids != starredArtistIds { starredArtistIds = ids }
    }

    private func loadRecentlyPlayed() async {
        guard visibleCarousels.contains(.recentlyPlayed) else { return }
        for await event in LibraryLoader.load(.recentAlbums(), shown: recentlyPlayed) {
            switch event {
            case .cached(let albums), .fresh(let albums):
                if albums != recentlyPlayed { recentlyPlayed = albums }
                settle(.recentlyPlayed)
            case .upToDate, .failed:
                break
            }
        }
        settle(.recentlyPlayed)
    }

    /// The top playlists show at once from the last ranking (kept in the library cache), then the
    /// ranking is recomputed — unless it ran recently — and replaces it only if it changed.
    ///
    /// Subsonic exposes no play count for playlists, so a playlist's count is the sum of its
    /// songs' play counts, fetched per playlist — a few at a time, not all at once.
    private func loadTopPlaylists(runExpensive: Bool) async {
        guard visibleCarousels.contains(.topPlaylists) else { return }
        if topPlaylists.isEmpty, let remembered = await Self.rememberedTopPlaylists() {
            topPlaylists = remembered
        }
        settle(.topPlaylists)
        guard runExpensive else { return }

        var playlists: [PlaylistSummary] = []
        for await event in LibraryLoader.load(.allPlaylists(), shown: nil) {
            switch event {
            case .cached(let cached), .fresh(let cached):
                playlists = cached
            case .upToDate, .failed:
                break
            }
        }
        guard !playlists.isEmpty, !Task.isCancelled else { return }
        let client = client
        let counts = await BoundedConcurrency.map(playlists, limit: Self.playlistFetchLimit) { playlist -> (String, Int) in
            let songs = (try? await client.getPlaylist(id: playlist.id.raw))?.entry ?? []
            return (playlist.id.raw, songs.reduce(0) { $0 + ($1.playCount ?? 0) })
        }
        guard !Task.isCancelled else { return }
        let ranked = HomeLoadingPolicy.rank(
            playlists, playCounts: Dictionary(counts, uniquingKeysWith: { first, _ in first }),
            limit: HomeAlbumSections.carouselLimit
        )
        if ranked != topPlaylists { topPlaylists = ranked }
        let ids = ranked.map(\.id.raw)
        await LibraryCacheDatabase.shared.set(ids, category: Self.rankingCategory, key: Self.rankingKey)
    }

    private static let playlistFetchLimit = 6
    private static let rankingCategory = "home"
    private static let rankingKey = "topPlaylists"

    /// The last ranking, resolved against the cached playlists.
    private static func rememberedTopPlaylists() async -> [PlaylistSummary]? {
        guard let ids = await LibraryCacheDatabase.shared.get([String].self, category: rankingCategory, key: rankingKey),
              !ids.isEmpty,
              let cached = await LibraryCacheDatabase.shared.cachedAllPlaylists() else { return nil }
        let byId = Dictionary(cached.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = ids.compactMap { byId[$0] }
        return resolved.isEmpty ? nil : resolved
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
