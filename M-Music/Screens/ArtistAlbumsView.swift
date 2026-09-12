//
//  ArtistAlbumsView.swift
//  M-Music
//
//  Created by Ivan on 12.09.2026.
//

import SwiftUI

private enum ArtistAlbumSortField: LocalizedStringKey, CaseIterable {
    case title = "Title"
    case year = "Year"

    var storageKey: String {
        switch self {
        case .title: return "title"
        case .year: return "year"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .title
    }
}

private enum ArtistAlbumSortOrder: LocalizedStringKey, CaseIterable {
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

struct ArtistAlbumsView: View {
    let artist: ArtistID3

    private let client = SubsonicClient.shared
    private let player = PlayerManager.shared

    @Namespace private var albumZoomNamespace

    @State private var albums: [AlbumID3] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false
    @State private var isLoadingQueue = false
    @State private var isStarred: Bool

    @AppStorage("artistAlbums.sortField") private var sortFieldStorage = ArtistAlbumSortField.title.storageKey
    @AppStorage("artistAlbums.sortOrder") private var sortOrderStorage = ArtistAlbumSortOrder.ascending.storageKey

    private var sortField: Binding<ArtistAlbumSortField> {
        Binding(
            get: { ArtistAlbumSortField(storageKey: sortFieldStorage) },
            set: { sortFieldStorage = $0.storageKey }
        )
    }
    private var sortOrder: Binding<ArtistAlbumSortOrder> {
        Binding(
            get: { ArtistAlbumSortOrder(storageKey: sortOrderStorage) },
            set: { sortOrderStorage = $0.storageKey }
        )
    }

    /// Computed once in `init`, not inline — same reasoning as `AlbumView.artworkURL`:
    /// `coverArtURL` signs every call with a fresh random token, so recomputing it in `body`
    /// would hand `CachedAsyncImage` a "new" URL on every re-render.
    @State private var artworkURL: URL?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    init(artist: ArtistID3) {
        self.artist = artist
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: artist.coverArt ?? artist.id.raw))
        _isStarred = State(initialValue: artist.isStarred)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                artistHeader
                actionButtons
                albumsGrid
            }
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .toolbar {
            starButton
            sortButton
        }
        .onAppear {
            refresh()
        }
    }

    private var artistHeader: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(url: artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.mic")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 160, height: 160)
            .clipShape(Circle())

            Text(artist.name)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
        }
    }

    /// Same width as one `AlbumCardView` cell — the two buttons share the row using the same
    /// horizontal padding and inter-item spacing as `albumsGrid`'s `LazyVGrid`, so each button
    /// ends up exactly as wide as one flexible grid column.
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                play()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
            .disabled(albums.isEmpty || isLoadingQueue)

            Button {
                shuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
            .disabled(albums.isEmpty || isLoadingQueue)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
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
        } else if albums.isEmpty {
            Text("No albums found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(sortedAlbums) { album in
                    NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                        AlbumCardView(album: album, zoomNamespace: albumZoomNamespace, subtitle: .year)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var sortedAlbums: [AlbumID3] {
        albums.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField.wrappedValue {
            case .title:
                comparison = lhs.name.sortKey.localizedStandardCompare(rhs.name.sortKey)
            case .year:
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                comparison = lhsYear == rhsYear ? .orderedSame : (lhsYear < rhsYear ? .orderedAscending : .orderedDescending)
            }
            return sortOrder.wrappedValue == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    @ToolbarContentBuilder
    private var starButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleStarred()
            } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .foregroundStyle(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var sortButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: sortField) {
                    ForEach(ArtistAlbumSortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.inline)

                Picker("Order", selection: sortOrder) {
                    ForEach(ArtistAlbumSortOrder.allCases, id: \.self) { order in
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

    private func toggleStarred() {
        let newValue = !isStarred
        isStarred = newValue
        Task {
            do {
                if newValue {
                    try await client.star(artistIds: [artist.id.raw])
                } else {
                    try await client.unstar(artistIds: [artist.id.raw])
                }
            } catch {
                await MainActor.run { isStarred = !newValue }
            }
        }
    }

    /// Called from `.onAppear`, which fires every time this screen becomes visible again —
    /// including when popping back from a pushed album. Only the very first load shows the
    /// spinner and replaces the grid; later calls refetch quietly in the background and just
    /// update `albums` in place once done, so the grid's view identity (and the ScrollView's
    /// scroll position) stays stable instead of being torn down and rebuilt, which was also
    /// breaking the album's zoom-dismiss transition mid-animation. Mirrors `LibraryView.refresh()`.
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
                let fetched = try await client.getArtist(id: artist.id.raw)
                await MainActor.run {
                    albums = fetched.album
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

    /// There's no "songs by artist" endpoint in the Subsonic API — Play/Shuffle instead fetch
    /// every album's tracklist (concurrently) and concatenate them in album order.
    private func fetchAllSongs() async throws -> [Child] {
        try await withThrowingTaskGroup(of: (Int, [Child]).self) { group in
            for (index, album) in albums.enumerated() {
                group.addTask {
                    let songs = try await client.getAlbum(id: album.id.raw).song ?? []
                    return (index, songs)
                }
            }
            var results = [[Child]](repeating: [], count: albums.count)
            for try await (index, songs) in group {
                results[index] = songs
            }
            return results.flatMap { $0 }
        }
    }

    private func play() {
        runQueue { $0 }
    }

    private func shuffle() {
        runQueue { $0.shuffled() }
    }

    private func runQueue(_ transform: @escaping ([Child]) -> [Child]) {
        guard !albums.isEmpty, !isLoadingQueue else { return }
        isLoadingQueue = true
        Task {
            let songs = (try? await fetchAllSongs()) ?? []
            await MainActor.run {
                isLoadingQueue = false
                let queue = transform(songs)
                guard !queue.isEmpty else { return }
                player.play(queue: queue, startAt: 0)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ArtistAlbumsView(
            artist: ArtistID3(id: "1", name: "Archspire", coverArt: nil, albumCount: 3, starred: nil, userRating: nil)
        )
    }
}
