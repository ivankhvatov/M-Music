//
//  AlbumsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

private enum AlbumFilterOption: LocalizedStringKey, CaseIterable {
    case all = "All albums"
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

private enum AlbumSortField: LocalizedStringKey, CaseIterable {
    case title = "Title"
    case artist = "Artist"
    case year = "Year"

    var storageKey: String {
        switch self {
        case .title: return "title"
        case .artist: return "artist"
        case .year: return "year"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .title
    }
}

private enum AlbumSortOrder: LocalizedStringKey, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

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

struct AlbumsListView: View {
    @Namespace private var albumZoomNamespace
    @Environment(\.displayScale) private var displayScale

    private let client = SubsonicClient.shared

    @State private var searchText = ""

    @AppStorage("albumsList.filterOption") private var filterOptionStorage = AlbumFilterOption.all.storageKey
    @AppStorage("albumsList.sortField") private var sortFieldStorage = AlbumSortField.title.storageKey
    @AppStorage("albumsList.sortOrder") private var sortOrderStorage = AlbumSortOrder.ascending.storageKey
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false
    @AppStorage("library.albumsDisplayStyle") private var displayStyleStorage = LibraryDisplayStyle.grid.storageKey

    private var filterOption: Binding<AlbumFilterOption> {
        Binding(
            get: { AlbumFilterOption(storageKey: filterOptionStorage) },
            set: { filterOptionStorage = $0.storageKey }
        )
    }
    private var sortField: Binding<AlbumSortField> {
        Binding(
            get: { AlbumSortField(storageKey: sortFieldStorage) },
            set: { sortFieldStorage = $0.storageKey }
        )
    }
    private var sortOrder: Binding<AlbumSortOrder> {
        Binding(
            get: { AlbumSortOrder(storageKey: sortOrderStorage) },
            set: { sortOrderStorage = $0.storageKey }
        )
    }
    private var displayStyle: LibraryDisplayStyle {
        LibraryDisplayStyle(storageKey: displayStyleStorage)
    }

    @State private var albums: [AlbumID3] = []
    /// Cached result of filtering/sorting `albums`, recomputed only by `recompute()`
    /// (see its call sites) rather than on every `body` evaluation — `body` reads it 2-3 times a
    /// pass, and re-filtering/re-sorting a whole library each time (plus again on every
    /// `DownloadStore`/`LibraryCacheStatus` publish) was a big part of the CPU cost of opening
    /// this screen. Same approach `SongsListView` already uses.
    @State private var displayedAlbums: [AlbumID3] = []
    /// `albums`, sorted by the current field/order — recomputed only when `albums` or the sort
    /// changes (`markSortStale()`). Filtering (`recompute()`) then works on this
    /// already-sorted array and preserves its order, so a search keystroke or a downloads publish
    /// never pays for re-sorting the whole library (an ICU collation per comparison).
    @State private var sortedAlbums: [AlbumID3] = []
    /// Sorts/groups/filters off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInLists) private var showUnavailableInLists = true

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

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
            } else if displayedAlbums.isEmpty {
                Text("No albums found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch displayStyle {
                case .grid:
                    ScrollView {
                        albumsGrid
                    }
                case .list:
                    albumsList
                }
            }
        }
        .refreshable { await performRefresh(force: true) }
        .navigationTitle("Albums")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            filterButton
            sortButton
        }
        .task { await refresh() }
        .onChange(of: searchText) { recompute(debounced: true) }
        .onChange(of: filterOptionStorage) { recompute() }
        .onChange(of: sortFieldStorage) { markSortStale() }
        .onChange(of: sortOrderStorage) { markSortStale() }
        .onChange(of: groupReleaseVersionsEnabled) { recompute() }
        .onChange(of: showUnavailableInLists) { recompute() }
        .onChange(of: networkMonitor.isOnline) { recompute() }
        .onChange(of: downloads.revision) { if offlineFilterActive { recompute() } }
        .onChange(of: libraryCacheStatus.revision) { if offlineFilterActive { recompute() } }
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(displayedAlbums) { album in
                NavigationLink(destination: LazyDestination { AlbumView(album: album, zoomNamespace: albumZoomNamespace) }) {
                    AlbumCardView(album: album, zoomNamespace: albumZoomNamespace)
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable(album))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var albumsList: some View {
        List {
            ForEach(displayedAlbums) { album in
                NavigationLink(destination: LazyDestination { AlbumView(album: album, zoomNamespace: albumZoomNamespace) }) {
                    AlbumRow(album: album, zoomNamespace: albumZoomNamespace, displayScale: displayScale)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .disabled(!isAvailable(album))
            }
        }
        .listStyle(.plain)
    }

    /// Same expression `AlbumCardView`/`AlbumRow` compute internally for their own dimming — this
    /// is the only way to also `.disabled(...)` the `NavigationLink` they're the label of, since
    /// that can't be done from inside the label itself.
    private func isAvailable(_ album: AlbumID3) -> Bool {
        networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw)
    }

    /// Everything the derivation needs, captured by value so it can run off the main actor.
    private struct DerivationSpec: Sendable {
        var field: AlbumSortField
        var ascending: Bool
        var favoritesOnly: Bool
        var groupVersions: Bool
        var search: String
    }

    /// The items or the sort changed: the next derivation has to sort again.
    private func markSortStale() {
        deriver.sortStale = true
        recompute()
    }

    /// Re-derives `sortedAlbums` (only if the items or sort changed) and `displayedAlbums` off the
    /// main actor and applies the newest result. The sort, release-version grouping and search
    /// filter over a whole library used to run synchronously on the main actor, on open and again
    /// on every search keystroke.
    private func recompute(debounced: Bool = false) {
        let items = albums
        let alreadySorted = sortedAlbums
        let needsSort = deriver.sortStale
        let spec = DerivationSpec(
            field: sortField.wrappedValue,
            ascending: sortOrder.wrappedValue == .ascending,
            favoritesOnly: filterOption.wrappedValue == .favoritesOnly,
            groupVersions: groupReleaseVersionsEnabled,
            search: searchText
        )
        deriver.run(delay: debounced ? .milliseconds(200) : nil, {
            let sorted = needsSort ? Self.sorted(items, spec) : alreadySorted
            return (sorted: sorted, displayed: Self.filtered(sorted, spec))
        }, apply: { result in
            deriver.sortStale = false
            sortedAlbums = result.sorted
            // The offline filter reads main-actor stores, and is a cheap lookup per album.
            displayedAlbums = offlineFilterActive
                ? result.displayed.filter {
                    libraryCacheStatus.isAlbumFullyDownloaded(albumId: $0.id.raw, downloads: downloads)
                }
                : result.displayed
            isLoading = false
        })
    }

    /// Sorts the whole library by the current field/order. `sortedByLocalizedKey` computes each
    /// title/artist key once rather than on both sides of every comparison.
    private nonisolated static func sorted(_ list: [AlbumID3], _ spec: DerivationSpec) -> [AlbumID3] {
        switch spec.field {
        case .title:
            return list.sortedByLocalizedKey(ascending: spec.ascending) { $0.name.sortKey }
        case .artist:
            return list.sortedByLocalizedKey(ascending: spec.ascending) { ($0.artist ?? "").sortKey }
        case .year:
            return list.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                return spec.ascending ? lhsYear < rhsYear : lhsYear > rhsYear
            }
        }
    }

    /// Whether the offline "hide what isn't downloaded" filter is currently in effect — the only
    /// case in which downloads/library-cache changes can alter what's displayed.
    private var offlineFilterActive: Bool {
        !networkMonitor.isOnline && !showUnavailableInLists
    }

    /// Filters the already-sorted albums — every step below preserves its order, except
    /// grouping release versions, which can put a group's preferred version somewhere other than
    /// where its first member sat (only matters for non-title sorts, where members can differ in
    /// year/artist string), so those re-sort the (much smaller) grouped result.
    private nonisolated static func filtered(_ sorted: [AlbumID3], _ spec: DerivationSpec) -> [AlbumID3] {
        var result = sorted

        if spec.favoritesOnly {
            result = result.filter { $0.isStarred }
        }

        if spec.groupVersions && !spec.favoritesOnly {
            result = result.groupedByPreferredVersion()
            if spec.field != .title {
                result = Self.sorted(result, spec)
            }
        }

        if !spec.search.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(spec.search)
                    || ($0.artist?.localizedCaseInsensitiveContains(spec.search) ?? false)
            }
        }

        return result
    }

    /// Stale-while-revalidate: shows cached albums immediately (no spinner) if any are cached,
    /// then revalidates against the server and only touches the displayed list if the fresh
    /// result actually differs from what's already shown. Loading, the "did anything change?"
    /// check and the cache write all happen in `LibraryLoader`, off the main actor; this only
    /// applies what it reports. Runs from `.task`, so leaving the screen cancels it.
    private func refresh() async {
        guard client.isConfigured else {
            albums = []
            sortedAlbums = []
            displayedAlbums = []
            deriver.cancel()
            hasLoadedOnce = false
            return
        }
        // Only the very first load shows the spinner (and thus swaps out the list) — a quiet
        // reappearance (e.g. popping back from a pushed `AlbumView`) must never briefly tear
        // down the grid's identity, or it resets scroll position and breaks an in-flight
        // zoom-dismiss transition (the grid row IS the transition's source view).
        if !hasLoadedOnce {
            isLoading = true
        }
        await performRefresh()
    }

    /// `force` skips the "has the server library changed?" check, for pull-to-refresh.
    private func performRefresh(force: Bool = false) async {
        guard client.isConfigured else { return }
        // The spinner stays up until the first derivation lands, rather than flashing "No albums
        // found." while the (now off-main) sort is still running.
        defer { if !deriver.isPending { isLoading = false } }
        for await event in LibraryLoader.load(.allAlbums(), shown: albums, force: force) {
            switch event {
            case .cached(let cached):
                albums = cached
                hasLoadedOnce = true
                markSortStale()
            case .fresh(let fetched):
                loadError = nil
                hasLoadedOnce = true
                albums = fetched
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
                if albums.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var filterButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Filter", selection: filterOption) {
                    ForEach(AlbumFilterOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.horizontal.3.decrease")
                    .foregroundStyle(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var sortButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: sortField) {
                    ForEach(AlbumSortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.inline)

                Picker("Order", selection: sortOrder) {
                    ForEach(AlbumSortOrder.allCases, id: \.self) { order in
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
}

/// A single row for the "List"-style albums browse — rounded-corner artwork on the leading edge
/// (mirrors `AlbumCardView.artwork`, but fit rather than cropped to a square — see `artwork`
/// below), title/artist stacked next to it (mirrors `ArtistsListView.ArtistRow`, which uses a
/// circular artwork with just a title).
private struct AlbumRow: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    /// Computed once, in `init` — not via `.task` — so an already-cached cover (e.g. already
    /// fetched by this same row earlier) renders on the very first frame instead of flashing the
    /// placeholder. Mirrors `SongRow.artworkURL`'s doc comment.
    ///
    /// Requested downscaled to this row's own size (like `SongRow`), not the full original the
    /// grid card and `AlbumView` both request — a screen full of list rows fetching and decoding
    /// full-size covers just to show them at `rowArtworkSize` is wasted bandwidth and memory.
    /// That does mean this doesn't share `AlbumView`'s cache entry the way the grid card does —
    /// `.task` below separately prefetches the full-size cover in the background so opening
    /// `AlbumView` from this row is still lag-free, without paying full-size decode cost for the
    /// row itself.
    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.album
    private let artworkCornerRadius: CGFloat = 4

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    init(album: AlbumID3, zoomNamespace: Namespace.ID? = nil, displayScale: CGFloat) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        let pixelSize = ImageCache.RowArtwork.pixels(rowArtworkSize, scale: displayScale)
        _artworkURL = State(initialValue: SubsonicClient.shared.cachedCoverArtURL(forId: album.coverArt ?? album.id.raw, size: pixelSize))
    }

    var body: some View {
        HStack(spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name + (album.version != nil ? (" (" + album.version! + ")") : ""))
                    .font(.system(size: 18))
                    .lineLimit(1)
                Text(album.artist ?? "Unknown Artist")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .dimmedIfUnavailable(networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw))
        // Full-size cover's bytes, prefetched to disk in the background (no decode — the row
        // itself only shows the small thumbnail) — see `artworkURL`'s doc comment. Keyed to
        // `album.id` so scrolling this row's cell to a different album (cell reuse) cancels the
        // stale prefetch and starts the right one.
        .task(id: album.id) {
            await ImageCache.shared.prefetchOriginalData(try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw))
        }
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
                        .stroke(Color.secondary, lineWidth: 0.1)
                )
        } placeholder: {
            RoundedRectangle(cornerRadius: artworkCornerRadius)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: rowArtworkSize, height: rowArtworkSize)

        if let zoomNamespace {
            image.matchedTransitionSource(id: album.id, in: zoomNamespace)
        } else {
            image
        }
    }
}

#Preview {
    NavigationStack {
        AlbumsListView()
    }
}
