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

    private let client = SubsonicClient.shared

    @State private var searchText = ""

    @AppStorage("albumsList.filterOption") private var filterOptionStorage = AlbumFilterOption.all.storageKey
    @AppStorage("albumsList.sortField") private var sortFieldStorage = AlbumSortField.title.storageKey
    @AppStorage("albumsList.sortOrder") private var sortOrderStorage = AlbumSortOrder.ascending.storageKey

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
            ScrollView {
                albumsGrid
            }
            .navigationTitle("Albums")
            .searchable(text: $searchText, prompt: "Search albums")
            .toolbar {
                filterButton
                sortButton
            }
            .onAppear {
                refresh()
            }
        }
    }

    @ViewBuilder
    private var albumsGrid: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else if displayedAlbums.isEmpty {
            Text("No albums found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
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
    }

    private var displayedAlbums: [AlbumID3] {
        var result = albums

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { $0.isStarred }
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

#Preview {
    AlbumsListView()
}
