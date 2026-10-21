//
//  ArtistsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

private enum ArtistFilterOption: LocalizedStringKey, CaseIterable {
    case all = "All artists"
    case favoritesOnly = "Favorite only"

    /// Stable, non-localized identifier for persisting the selection — `rawValue` is a
    /// `LocalizedStringKey` and isn't suitable for storage.
    var storageKey: String {
        switch self {
        case .all: return "all"
        case .favoritesOnly: return "favoritesOnly"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .all
    }
}

private enum ArtistSortOrder: LocalizedStringKey, CaseIterable {
    case ascending = "Name: A-Z"
    case descending = "Name: Z-A"

    var storageKey: String {
        switch self {
        case .ascending: return "ascending"
        case .descending: return "descending"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .ascending
    }
}

struct ArtistsListView: View {
    private let client = SubsonicClient.shared
    @Environment(\.displayScale) private var displayScale

    @State private var searchText = ""
    @State private var artists: [ArtistID3] = []
    /// Cached result of filtering/sorting `artists`, recomputed only by `recompute()`
    /// rather than on every `body` evaluation — see `AlbumsListView.displayedAlbums`.
    @State private var displayedArtists: [ArtistID3] = []
    /// `artists` sorted by the current order, recomputed only when `artists` or the order
    /// changes — see `AlbumsListView.sortedAlbums`.
    @State private var sortedArtists: [ArtistID3] = []
    /// Sorts/filters off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false
    /// Keeps the content hidden on first open until the first screenful's images are in memory.
    @State private var imageReadiness = ImageReadiness()
    /// Where each displayed row is, for warming the ones below a row that scrolls into view.
    @State private var rowPositions = RowPositions()
    /// Where the user last was, to warm around on resume — see `onAppResume`.
    @State private var lastSeen = LastSeenIndex()

    @AppStorage("artistsList.filterOption") private var filterOptionStorage = ArtistFilterOption.all.storageKey
    @AppStorage("artistsList.sortOrder") private var sortOrderStorage = ArtistSortOrder.ascending.storageKey
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInLists) private var showUnavailableInLists = true

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared

    private var filterOption: Binding<ArtistFilterOption> {
        Binding(
            get: { ArtistFilterOption(storageKey: filterOptionStorage) },
            set: { filterOptionStorage = $0.storageKey }
        )
    }
    private var sortOrder: Binding<ArtistSortOrder> {
        Binding(
            get: { ArtistSortOrder(storageKey: sortOrderStorage) },
            set: { sortOrderStorage = $0.storageKey }
        )
    }

    var body: some View {
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
            } else if displayedArtists.isEmpty {
                Text("No artists found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !imageReadiness.isReady {
                // Opened before the first screenful's images were ready: hold the content back
                // until they are (see `ImageReadiness`) rather than showing placeholders.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(displayedArtists) { artist in
                        NavigationLink(destination: LazyDestination { ArtistAlbumsView(artist: artist) }) {
                            ArtistRow(artist: artist, displayScale: displayScale)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .disabled(!isAvailable(artist))
                        .onAppear { warmAhead(after: artist) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await performRefresh(force: true) }
        .onAppResume { warmAround(lastSeen.index) }
        .navigationTitle("Artists")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            filterButton
            sortButton
        }
        .task { await refresh() }
        .onChange(of: searchText) { recompute(debounced: true) }
        .onChange(of: filterOptionStorage) { recompute() }
        .onChange(of: sortOrderStorage) { markSortStale() }
        .onChange(of: showUnavailableInLists) { recompute() }
        .onChange(of: networkMonitor.isOnline) { recompute() }
        .onChange(of: downloads.revision) { if offlineFilterActive { recompute() } }
        .onChange(of: libraryCacheStatus.revision) { if offlineFilterActive { recompute() } }
    }

    /// Everything the derivation needs, captured by value so it can run off the main actor.
    private struct DerivationSpec: Sendable {
        var ascending: Bool
        var favoritesOnly: Bool
        var search: String
    }

    /// The items or the sort changed: the next derivation has to sort again.
    private func markSortStale() {
        deriver.sortStale = true
        recompute()
    }

    /// Re-derives `sortedArtists` (only if the items or sort changed) and `displayedArtists` off
    /// the main actor and applies the newest result — see `OffMainDeriver`.
    private func recompute(debounced: Bool = false) {
        let items = artists
        let alreadySorted = sortedArtists
        let needsSort = deriver.sortStale
        let spec = DerivationSpec(
            ascending: sortOrder.wrappedValue == .ascending,
            favoritesOnly: filterOption.wrappedValue == .favoritesOnly,
            search: searchText
        )
        deriver.run(delay: debounced ? .milliseconds(200) : nil, {
            let sorted = needsSort
                ? items.sortedByLocalizedKey(ascending: spec.ascending) { $0.name.sortKey }
                : alreadySorted
            return (sorted: sorted, displayed: Self.filtered(sorted, spec))
        }, apply: { result in
            deriver.sortStale = false
            sortedArtists = result.sorted
            // The offline filter reads main-actor stores, and is a cheap lookup per artist.
            displayedArtists = offlineFilterActive
                ? result.displayed.filter {
                    libraryCacheStatus.hasFullyDownloadedAlbum(artistId: $0.id.raw, downloads: downloads)
                }
                : result.displayed
            isLoading = false
            rememberFirstScreenful()
        })
    }

    private func artworkRequests(for artists: ArraySlice<ArtistID3>) -> [ArtworkRequest] {
        artists.map { ArtworkRequest.artistRow($0.coverArt ?? $0.id.raw, scale: displayScale) }
    }

    /// A row scrolled into view: warm the ones just below it, so a fast scroll finds them ready.
    private func warmAhead(after artist: ArtistID3) {
        guard let index = rowPositions.position(of: artist.id.raw),
              displayedArtists.indices.contains(index), displayedArtists[index].id == artist.id else { return }
        lastSeen.index = index
        warmAround(index)
    }

    /// Warms the images around `index` — also after the app resumes, where the user left off.
    private func warmAround(_ index: Int) {
        guard displayedArtists.indices.contains(index) else { return }
        let requests = artworkRequests(for: ArraySlice(ImageWarmer.neighbors(of: index, in: displayedArtists, count: ImageWarmer.scrollAheadCount)))
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests, source: "artists") }
    }

    /// Tells `ImageWarmer` what this screen shows first, so its artwork is decoded ahead of the
    /// next visit (a search's results aren't what the screen normally opens with).
    private func rememberFirstScreenful() {
        rowPositions.update(ids: displayedArtists.map { $0.id.raw })
        let requests = artworkRequests(for: displayedArtists.prefix(ImageWarmer.manifestLimit))
        imageReadiness.require(requests)
        guard searchText.isEmpty else { return }
        Task { await ImageWarmer.shared.remember(.artists, requests) }
    }

    /// See `AlbumsListView.offlineFilterActive`.
    private var offlineFilterActive: Bool {
        !networkMonitor.isOnline && !showUnavailableInLists
    }

    /// Filters the already-sorted artists, preserving their order.
    private nonisolated static func filtered(_ sorted: [ArtistID3], _ spec: DerivationSpec) -> [ArtistID3] {
        var result = sorted
        if spec.favoritesOnly {
            result = result.filter { $0.isStarred }
        }
        if !spec.search.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(spec.search) }
        }
        return result
    }

    @ToolbarContentBuilder
    private var filterButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Filter", selection: filterOption) {
                    ForEach(ArtistFilterOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var sortButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: sortOrder) {
                    ForEach(ArtistSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.primary)
            }
        }
    }

    /// Stale-while-revalidate: shows cached artists immediately (no spinner) if any are cached,
    /// then revalidates against the server and only touches the displayed list if the fresh
    /// result actually differs from what's already shown. Loading, the "did anything change?"
    /// check and the cache write all happen in `LibraryLoader`, off the main actor; this only
    /// applies what it reports. Runs from `.task`, so leaving the screen cancels it.
    private func refresh() async {
        guard client.isConfigured else {
            artists = []
            sortedArtists = []
            displayedArtists = []
            deriver.cancel()
            hasLoadedOnce = false
            return
        }
        // Only the very first load shows the spinner (and thus swaps out the list) — a quiet
        // reappearance (e.g. popping back from a pushed detail screen) must never briefly tear
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
        // The spinner stays up until the first derivation lands, rather than flashing "No artists
        // found." while the (now off-main) sort is still running.
        defer { if !deriver.isPending { isLoading = false } }
        for await event in LibraryLoader.load(.allArtists(), shown: artists, force: force) {
            switch event {
            case .cached(let cached):
                artists = cached
                hasLoadedOnce = true
                markSortStale()
            case .fresh(let fetched):
                loadError = nil
                hasLoadedOnce = true
                artists = fetched
                markSortStale()
            case .upToDate:
                loadError = nil
                hasLoadedOnce = true
                if !deriver.isPending { isLoading = false }
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                if !deriver.isPending { isLoading = false }
                if artists.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    /// Same expression `ArtistRow` computes internally for its own dimming — this is the only
    /// way to also `.disabled(...)` the `NavigationLink` it's the label of.
    private func isAvailable(_ artist: ArtistID3) -> Bool {
        networkMonitor.isOnline || downloads.hasDownloadedSong(byArtist: artist.name)
    }
}

private struct ArtistRow: View {
    let artist: ArtistID3

    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.artist

    /// Requests the row-sized thumbnail, not the full picture the artist's own screen uses — a
    /// 48pt avatar has no use for the original, and a small download is also what the permanent
    /// cache saves for artists with downloaded songs (see `DownloadedArtwork`).
    init(artist: ArtistID3, displayScale: CGFloat) {
        self.artist = artist
        _artworkURL = State(initialValue: ArtworkRequest.artistRow(artist.coverArt ?? artist.id.raw, scale: displayScale).url)
    }

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: artworkURL, maxPixelSize: ImageCache.avatarMaxPixelSize, loadDelay: .milliseconds(50)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.mic")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: rowArtworkSize, height: rowArtworkSize)
            .clipShape(Circle())

            Text(artist.name)
                .font(.body)
        }
        .dimmedIfUnavailable(networkMonitor.isOnline || downloads.hasDownloadedSong(byArtist: artist.name))
        // The artist's own screen opens with its picture and first albums' covers already
        // decoded: fetched to disk, then decoded once the row has stayed on screen a moment —
        // see `ImageWarmer`. Keyed to `artist.id` so a reused cell cancels the stale one.
        .task(id: artist.id) {
            let artworkId = artist.coverArt ?? artist.id.raw
            await ImageCache.shared.prefetchOriginalData(ArtworkRequest.artistHeader(artworkId).url)
            await ImageWarmer.shared.warmArtist(id: artist.id.raw, artworkId: artworkId)
        }
    }
}

#Preview {
    NavigationStack {
        ArtistsListView()
    }
}
