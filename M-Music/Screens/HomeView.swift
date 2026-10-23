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
    var genres: [GenreCarousel] = []

    /// One "Random genres" carousel.
    struct GenreCarousel: Equatable, Sendable, Identifiable {
        let name: String
        let albums: [AlbumID3]
        var id: String { name.lowercased() }
    }

    static let carouselLimit = 20
    /// A genre needs at least this many albums to get a carousel of its own.
    static let minimumGenreAlbums = 3

    /// `starredArtistIds` empty means "none starred (or not loaded yet)".
    static func make(
        from albums: [AlbumID3], starredArtistIds: Set<String>, groupVersions: Bool,
        genreSources: [GenreCarousel] = []
    ) -> HomeAlbumSections {
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
        // `genreSources` are the picked genres with every album the server lists under them;
        // "Group release versions" and the limit apply here like to the other carousels.
        let genres = genreSources.map { source in
            GenreCarousel(
                name: source.name,
                albums: Array((groupVersions ? source.albums.groupedByPreferredVersion() : source.albums).shuffled().prefix(limit))
            )
        }
        return HomeAlbumSections(
            random: Array(candidates.shuffled().prefix(limit)),
            latestReleases: Array(latest),
            recentlyAdded: Array(added),
            favoriteArtists: Array(favorites),
            genres: genres
        )
    }
}

/// What Home needs on its first frame, and when its slower parts are worth repeating.
enum HomeLoadingPolicy {
    /// How many cards of each carousel are on the first screen, about.
    static let cardsPerCarousel = 3

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
            case .randomAlbums, .latestReleases, .recentlyAdded, .favoriteArtistAlbums, .randomGenres: parts.insert(.library)
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

    @State private var isConnected = SubsonicClient.shared.isConfigured
    @State private var allAlbums: [AlbumID3] = []
    @State private var sections = HomeAlbumSections()
    @State private var starredArtistIds: Set<String> = []
    /// The starred artists the favorite-artists carousel was last picked for.
    @State private var favoritesBuiltFor: Set<String>?
    /// The genres the carousels were picked with, each with all the server's albums for it.
    @State private var pickedGenres: [HomeAlbumSections.GenreCarousel] = []
    /// Every genre on the server, for picking from.
    @State private var serverGenres: [Genre] = []
    @State private var recentlyPlayed: [AlbumID3] = []
    @State private var topPlaylists: [PlaylistSummary] = []
    /// Which albums and playlists are available offline — see `HomeAvailability`.
    @State private var availability = HomeAvailability.online
    @State private var availabilityTask: Task<Void, Never>?
    /// What the screen shows, built off the main actor by `HomeLayoutBuilder` from everything above
    /// and the settings: `body` only loops over it.
    @State private var layout = HomeLayout.empty
    @State private var layoutDeriver = OffMainDeriver()
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    /// Keeps the carousels hidden on first open until the first cards' images are in memory.
    @State private var imageReadiness = ImageReadiness()
    /// Builds the library-derived carousels off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()
    /// The parts the first frame is still waiting for (see `settle`).
    @State private var pendingParts: Set<HomeLoadingPolicy.Part> = []
    /// Set once every part the first frame waits for has its data: the next layout is the one whose
    /// images the first frame waits for.
    @State private var partsSettled = false
    @State private var gateRequested = false
    /// When the expensive requests last ran — see `HomeLoadingPolicy.shouldRunExpensiveRefresh`.
    @State private var lastExpensiveRefresh: Date?
    /// How many carousels are built so far — see `HomeReveal`.
    @State private var revealedCount = HomeReveal.initialCount
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false

    @AppStorage(HomeContentSettings.Keys.order) private var carouselOrderStorage = ""
    @AppStorage(HomeContentSettings.Keys.disabled) private var disabledCarouselsStorage = ""
    @AppStorage(HomeContentSettings.Keys.randomGenreCount) private var randomGenreCount = 0
    @AppStorage(GenreTranslationSettings.Keys.isEnabled) private var translateGenres = false

    private var visibleCarousels: [HomeCarouselKind] {
        HomeContentSettings.visible(
            order: carouselOrderStorage, disabled: disabledCarouselsStorage, randomGenreCount: randomGenreCount
        )
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
                    // Not lazy: a `LazyVStack` built each carousel (a scroll view, its cards, their
                    // links and images — about a hundred views) as it scrolled near and tore it down
                    // again after it, a dozen a second during a fling, all on the main thread. Built
                    // once and kept, vertical scrolling just moves them. The one-time build is
                    // spread out (`HomeReveal`) instead of stalling the moment Home appears; the
                    // cards inside each carousel stay lazy.
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(layout.carousels.prefix(revealedCount)) { carousel in
                            HomeCarouselView(model: carousel).equatable()
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .task(id: layout.carousels.count) { await revealRemainingCarousels() }
                }
            }
            // Background work holds off while this screen is scrolled — see `ScrollActivity`.
            .onScrollPhaseChange { _, phase in
                ScrollActivity.shared.set(scrolling: phase != .idle)
            }
            .onDisappear { ScrollActivity.shared.set(scrolling: false) }
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
            .onChange(of: randomGenreCount) {
                Task {
                    await pickGenres()
                    rebuildSections(reshuffle: false)
                }
            }
            .onChange(of: translateGenres) { rebuildLayout() }
            .onChange(of: GenreLocalizer.shared.revision) { rebuildLayout() }
            .onChange(of: carouselOrderStorage) { rebuildLayout() }
            .onChange(of: disabledCarouselsStorage) { rebuildLayout() }
            .onChange(of: imageReadiness.isReady) { _, isReady in
                if isReady { HomeWarmCoordinator.shared.warmAllCarousels() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { HomeWarmCoordinator.shared.resumed() }
            }
            // Connectivity and downloads decide what's available offline. Only the values are
            // read here; what they mean for each card is worked out off the main actor.
            .onReceive(NetworkMonitor.shared.$isOnline.removeDuplicates()) { isOnline in
                refreshAvailability(isOnline: isOnline)
            }
            .onReceive(DownloadStore.shared.$revision.removeDuplicates().dropFirst()) { _ in
                if !availability.isOnline { refreshAvailability(isOnline: false) }
            }
        }
    }

    // MARK: Layout

    /// Builds the carousels beyond the first few a couple at a time, so none of it happens during a
    /// scroll and none of it in one stall.
    private func revealRemainingCarousels() async {
        let total = layout.carousels.count
        revealedCount = HomeReveal.clamped(revealedCount, total: total)
        while revealedCount < total, !Task.isCancelled {
            try? await Task.sleep(for: HomeReveal.interval)
            guard !Task.isCancelled else { return }
            revealedCount = HomeReveal.next(revealedCount, total: layout.carousels.count)
        }
    }

    /// Builds the layout again off the main actor from the current data and settings (the newest
    /// request wins — `OffMainDeriver`), then hands it to the warm coordinator.
    private func rebuildLayout() {
        let order = carouselOrderStorage
        let disabled = disabledCarouselsStorage
        let genreCount = randomGenreCount
        let sections = sections
        // Localized here, on the main actor: the builder runs off it.
        let genreTitles = Dictionary(
            sections.genres.map { ($0.name, GenreLocalizer.shared.localized($0.name)) },
            uniquingKeysWith: { first, _ in first }
        )
        let played = recentlyPlayed
        let playlists = topPlaylists
        let availability = availability
        layoutDeriver.run({
            HomeLayoutBuilder.build(
                order: order, disabled: disabled, randomGenreCount: genreCount, genreTitles: genreTitles, sections: sections,
                recentlyPlayed: played, topPlaylists: playlists, availability: availability
            )
        }, apply: { built in
            if built != layout { layout = built }
            let coordinator = HomeWarmCoordinator.shared
            coordinator.update(built)
            // The first layout after everything the first frame waits for has arrived: its first
            // cards' images are what the spinner holds the carousels back for.
            if partsSettled, !gateRequested {
                gateRequested = true
                imageReadiness.require(built.firstScreenRequests)
            }
            if imageReadiness.isReady { coordinator.warmAllCarousels() }
            coordinator.rememberFirstScreen()
        })
    }

    private func refreshAvailability(isOnline: Bool) {
        availabilityTask?.cancel()
        availabilityTask = Task {
            let loaded = await HomeAvailabilityLoader.load(isOnline: isOnline)
            guard !Task.isCancelled, loaded != availability else { return }
            availability = loaded
            rebuildLayout()
        }
    }

    /// One of the parts the first frame waits for has its data (or has nothing to give). When the
    /// last one does, the spinner goes and the images of the first cards are awaited instead.
    /// Everything that arrives later fills its carousel in without holding anything back.
    private func settle(_ part: HomeLoadingPolicy.Part) {
        guard pendingParts.remove(part) != nil, pendingParts.isEmpty else { return }
        isLoading = false
        partsSettled = true
        rebuildLayout()
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
            if pendingParts.isEmpty, !deriver.isPending {
                // Nothing is still on its way: the layout built from what there is decides the gate.
                partsSettled = true
                rebuildLayout()
            }
        }

        async let starred: Void = loadStarredArtists(runExpensive: runExpensive)
        async let played: Void = loadRecentlyPlayed()
        async let playlists: Void = loadTopPlaylists(runExpensive: runExpensive)
        await loadLibrary()
        _ = await (starred, played, playlists)
        if runExpensive { lastExpensiveRefresh = Date() }
        await pickGenres()
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

    /// Picks the genres for the "Random genres" carousels from every genre on the server — not
    /// only those some album has as its primary genre — and downloads the albums listed under
    /// each. The picks are kept for 24 hours (`HomeGenrePicks`); the pinned ones that are still
    /// good stay and the remaining slots are filled at random. Without the server (offline), the
    /// genres of the cached albums stand in.
    private func pickGenres() async {
        let count = visibleCarousels.contains(.randomGenres) ? randomGenreCount : 0
        guard count > 0 else {
            if !pickedGenres.isEmpty { pickedGenres = [] }
            return
        }
        if serverGenres.isEmpty { serverGenres = (try? await client.getGenres()) ?? [] }
        let minimum = HomeAlbumSections.minimumGenreAlbums
        var pool: [String: String] = [:]
        for genre in serverGenres where genre.albumCount >= minimum {
            pool[genre.value.lowercased()] = genre.value
        }
        if pool.isEmpty {
            var counts: [String: (name: String, count: Int)] = [:]
            for album in allAlbums {
                for name in album.genreNames { counts[name.lowercased(), default: (name, 0)].count += 1 }
            }
            for (key, entry) in counts where entry.count >= minimum { pool[key] = entry.name }
        }
        let pinned = HomeGenrePicks.pinned()
        if !pickedGenres.isEmpty, !pinned.isEmpty, pickedGenres.count == min(count, pool.count) { return }

        let kept = pinned.compactMap { pool[$0.lowercased()] }.prefix(count)
        let keptKeys = Set(kept.map { $0.lowercased() })
        let fresh = pool.filter { !keptKeys.contains($0.key) }.values.shuffled()
        let names = Array((Array(kept) + fresh).prefix(count))

        let client = client
        let local = allAlbums
        let fetched = await withTaskGroup(of: (String, [AlbumID3]).self) { group -> [String: [AlbumID3]] in
            for name in names {
                group.addTask {
                    if let albums = try? await client.getAlbumList2(type: .byGenre, size: 500, genre: name), !albums.isEmpty {
                        return (name, albums)
                    }
                    let key = name.lowercased()
                    return (name, local.filter { $0.genreNames.contains { $0.lowercased() == key } })
                }
            }
            var result: [String: [AlbumID3]] = [:]
            for await (name, albums) in group { result[name] = albums }
            return result
        }
        guard !Task.isCancelled else { return }
        let sources = names.compactMap { name in
            fetched[name].flatMap { $0.isEmpty ? nil : HomeAlbumSections.GenreCarousel(name: name, albums: $0) }
        }
        pickedGenres = sources
        HomeGenrePicks.remember(sources.map(\.name))
    }

    /// `reshuffle` re-rolls the random picks; otherwise they stay put so a quiet refresh (popping
    /// back to Home) doesn't swap the cards under the user. The sorting and shuffling of the whole
    /// library run off the main actor, and only the newest request is applied (`OffMainDeriver`).
    private func rebuildSections(reshuffle: Bool) {
        let albums = allAlbums
        let starredIds = starredArtistIds
        let groupVersions = groupReleaseVersionsEnabled
        let genreSources = visibleCarousels.contains(.randomGenres) ? pickedGenres : []
        deriver.run({
            HomeAlbumSections.make(
                from: albums, starredArtistIds: starredIds, groupVersions: groupVersions, genreSources: genreSources
            )
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
            // The picks themselves are kept for 24 hours (`pickGenres`); the albums shown for them
            // are only redrawn when the picks change, so popping back from an album doesn't swap them.
            if next.genres.map(\.name) != genreSources.map(\.name) || (!genreSources.isEmpty && sections.genres.isEmpty) {
                next.genres = built.genres
            }
            favoritesBuiltFor = starredIds
            // Only a change re-renders the carousels.
            if next != sections { sections = next }
            // Whichever build is applied last settles the library part, so a build superseded
            // by a newer one never leaves it pending.
            settle(.library)
            rebuildLayout()
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
                if albums != recentlyPlayed {
                    recentlyPlayed = albums
                    rebuildLayout()
                }
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
            rebuildLayout()
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
        if ranked != topPlaylists {
            topPlaylists = ranked
            rebuildLayout()
        }
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
