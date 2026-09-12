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

    @State private var searchText = ""
    @State private var artists: [ArtistID3] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    @AppStorage("artistsList.filterOption") private var filterOptionStorage = ArtistFilterOption.all.storageKey
    @AppStorage("artistsList.sortOrder") private var sortOrderStorage = ArtistSortOrder.ascending.storageKey

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
                } else if displayedArtists.isEmpty {
                    Text("No artists found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(displayedArtists) { artist in
                            NavigationLink(destination: ArtistAlbumsView(artist: artist)) {
                                ArtistRow(artist: artist)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Artists")
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

    private var displayedArtists: [ArtistID3] {
        var result = artists

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { $0.isStarred }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        result.sort { lhs, rhs in
            let comparison = lhs.name.sortKey.localizedStandardCompare(rhs.name.sortKey)
            return sortOrder.wrappedValue == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
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

    private func refresh() {
        guard client.isConfigured else {
            artists = []
            hasLoadedOnce = false
            return
        }
        guard !isLoading else { return }

        if !hasLoadedOnce {
            isLoading = true
        }
        Task {
            do {
                let result = try await client.getArtists()
                let fetched = result.index.flatMap(\.artist)
                await MainActor.run {
                    artists = fetched
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
}

private struct ArtistRow: View {
    let artist: ArtistID3

    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = 54

    var body: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: artworkURL) { image in
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
                .font(.title3)
        }
        .task(id: artist.id) {
            artworkURL = try? SubsonicClient.shared.coverArtURL(forId: artist.coverArt ?? artist.id.raw)
        }
    }
}

#Preview {
    ArtistsListView()
}
