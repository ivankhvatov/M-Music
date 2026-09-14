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
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

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
            .navigationTitle("Albums")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                filterButton
                sortButton
            }
            .onAppear {
                refresh()
            }
        }
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(displayedAlbums) { album in
                NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                    AlbumCardView(album: album, zoomNamespace: albumZoomNamespace)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var albumsList: some View {
        List {
            ForEach(displayedAlbums) { album in
                NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                    AlbumRow(album: album, zoomNamespace: albumZoomNamespace, displayScale: displayScale)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    private var displayedAlbums: [AlbumID3] {
        var result = albums

        let isFavoritesOnly = filterOption.wrappedValue == .favoritesOnly
        if isFavoritesOnly {
            result = result.filter { $0.isStarred }
        }

        if groupReleaseVersionsEnabled && !isFavoritesOnly {
            result = result.groupedByPreferredVersion()
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        result.sort { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField.wrappedValue {
            case .title:
                comparison = lhs.name.sortKey.localizedStandardCompare(rhs.name.sortKey)
            case .artist:
                comparison = (lhs.artist ?? "").sortKey.localizedStandardCompare((rhs.artist ?? "").sortKey)
            case .year:
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                comparison = lhsYear == rhsYear ? .orderedSame : (lhsYear < rhsYear ? .orderedAscending : .orderedDescending)
            }
            return sortOrder.wrappedValue == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        return result
    }

    private func refresh() {
        guard client.isConfigured else {
            albums = []
            hasLoadedOnce = false
            return
        }
        guard !isLoading else { return }

        if !hasLoadedOnce {
            isLoading = true
        }
        Task {
            do {
                let fetched = try await fetchAllAlbums()
                await MainActor.run {
                    albums = fetched
                    loadError = nil
                    isLoading = false
                    hasLoadedOnce = true
                }
            } catch {
                await MainActor.run {
                    if !hasLoadedOnce {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }

    private func fetchAllAlbums() async throws -> [AlbumID3] {
        var result: [AlbumID3] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = try await client.getAlbumList2(type: .alphabeticalByName, size: pageSize, offset: offset)
            result.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return result
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
    /// That does mean this doesn't share `AlbumView`'s cache entry the way the grid card does, so
    /// opening the full view still fetches its own full-size cover.
    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = 64
    private let artworkCornerRadius: CGFloat = 4

    init(album: AlbumID3, zoomNamespace: Namespace.ID? = nil, displayScale: CGFloat) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        let pixelSize = Int(rowArtworkSize * displayScale)
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw, size: pixelSize))
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
    AlbumsListView()
}
