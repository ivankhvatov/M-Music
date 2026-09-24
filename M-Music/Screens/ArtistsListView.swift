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
    /// Cached result of filtering/sorting `artists`, recomputed only by `updateDisplayedArtists()`
    /// rather than on every `body` evaluation — see `AlbumsListView.displayedAlbums`.
    @State private var displayedArtists: [ArtistID3] = []
    /// `artists` sorted by the current order, recomputed only when `artists` or the order
    /// changes — see `AlbumsListView.sortedAlbums`.
    @State private var sortedArtists: [ArtistID3] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

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
                            .disabled(!isAvailable(artist))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .refreshable { await performRefresh(force: true) }
            .navigationTitle("Artists")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                filterButton
                sortButton
            }
            .onAppear {
                refresh()
                // So "does this artist have a fully-downloaded album" reads correctly offline
                // even before any live fetch has happened this session — guarded internally,
                // cheap to call again.
                Task(priority: .utility) { await LibraryCacheStatus.shared.preload() }
            }
            .onChange(of: searchText) { updateDisplayedArtists() }
            .onChange(of: filterOptionStorage) { updateDisplayedArtists() }
            .onChange(of: sortOrderStorage) { updateSortedArtists() }
            .onChange(of: showUnavailableInLists) { updateDisplayedArtists() }
            .onChange(of: networkMonitor.isOnline) { updateDisplayedArtists() }
            .onChange(of: downloads.downloadedSongIds) { if offlineFilterActive { updateDisplayedArtists() } }
            .onChange(of: libraryCacheStatus.albumSongCounts) { if offlineFilterActive { updateDisplayedArtists() } }
            .onChange(of: libraryCacheStatus.albumIdsByArtistId) { if offlineFilterActive { updateDisplayedArtists() } }
        }
    }

    private func updateSortedArtists() {
        sortedArtists = artists.sortedByLocalizedKey(ascending: sortOrder.wrappedValue == .ascending) { $0.name.sortKey }
        updateDisplayedArtists()
    }

    /// See `AlbumsListView.offlineFilterActive`.
    private var offlineFilterActive: Bool {
        !networkMonitor.isOnline && !showUnavailableInLists
    }

    /// Filters the already-sorted `sortedArtists`, preserving its order.
    private func updateDisplayedArtists() {
        var result = sortedArtists

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { $0.isStarred }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        if offlineFilterActive {
            result = result.filter {
                libraryCacheStatus.hasFullyDownloadedAlbum(artistId: $0.id.raw, downloads: downloads)
            }
        }

        displayedArtists = result
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
    /// then revalidates against the server in the background and only touches the displayed list
    /// (and re-caches) if the fresh result actually differs from what's already shown.
    private func refresh() {
        guard client.isConfigured else {
            artists = []
            sortedArtists = []
            displayedArtists = []
            hasLoadedOnce = false
            return
        }
        guard !isLoading else { return }
        // Only the very first load shows the spinner (and thus swaps out the list) — a quiet
        // reappearance (e.g. popping back from a pushed detail screen) must never briefly tear
        // down the list's identity, or it resets scroll position and breaks an in-flight
        // zoom-dismiss transition.
        if !hasLoadedOnce {
            isLoading = true
        }

        Task { await performRefresh() }
    }

    /// The actual load — cache first, then (unless nothing changed on the server) a fresh
    /// download. `force` skips that change check, for pull-to-refresh.
    private func performRefresh(force: Bool = false) async {
        guard client.isConfigured else { return }
        var hadCache = !artists.isEmpty
        if artists.isEmpty, let cached = await LibraryCacheDatabase.shared.cachedAllArtists() {
            await MainActor.run {
                artists = cached
                updateSortedArtists()
                hasLoadedOnce = true
                isLoading = false
            }
        }

        hadCache = hadCache || !artists.isEmpty

        // Nothing changed on the server since this list was last synced (see
        // `LibraryRevalidation`) — the cache we just showed is current, so skip the full
        // re-download. A forced refresh (pull-to-refresh) and a first load with no cache
        // always download.
        let check = await LibraryRevalidation.shared.check(.artists)
        if !force, hadCache, !check.needsRefetch {
            await MainActor.run {
                isLoading = false
                hasLoadedOnce = true
            }
            return
        }

        do {
            let result = try await client.getArtists()
            let fetched = result.index.flatMap(\.artist)
            let changed = fetched != artists
            await MainActor.run {
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
                if changed {
                    artists = fetched
                    updateSortedArtists()
                }
            }
            if changed {
                await LibraryCacheDatabase.shared.cacheAllArtists(fetched)
            }
            await LibraryRevalidation.shared.markSynced(.artists, token: check.token)
        } catch {
            // Offline, or the request otherwise failed — keep showing whatever's already on
            // screen (cache, or an earlier successful fetch); only surface an error if
            // there's truly nothing to show.
            await MainActor.run {
                isLoading = false
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

    private let rowArtworkSize: CGFloat = 48

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: artworkURL, maxPixelSize: ImageCache.avatarMaxPixelSize, loadDelay: .milliseconds(150)) { image in
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
        .task(id: artist.id) {
            artworkURL = try? SubsonicClient.shared.coverArtURL(forId: artist.coverArt ?? artist.id.raw)
        }
    }
}

#Preview {
    ArtistsListView()
}
