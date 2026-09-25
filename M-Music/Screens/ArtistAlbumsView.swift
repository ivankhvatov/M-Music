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

/// Buckets for the RELEASETYPE tag (OpenSubsonic), recognized case-insensitively in both
/// singular and plural form. `allCases` is declared in the exact order carousels should appear
/// in, with anything unrecognized (including no tag at all) falling into `.other`.
private enum ReleaseTypeCategory: LocalizedStringKey, CaseIterable, Hashable {
    case album = "Albums"
    case ep = "EPs"
    case single = "Singles"
    case compilation = "Compilations"
    case liveAlbum = "Live albums"
    case instrumental = "Instrumentals"
    case other = "Other"

    init(rawTag: String?) {
        switch (rawTag ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "album", "albums": self = .album
        case "ep", "eps": self = .ep
        case "single", "singles": self = .single
        case "compilation", "compilations": self = .compilation
        case "live album", "live albums": self = .liveAlbum
        case "instrumental", "instrumentals": self = .instrumental
        default: self = .other
        }
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

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInLists) private var showUnavailableInLists = true

    @AppStorage("artistAlbums.sortField") private var sortFieldStorage = ArtistAlbumSortField.title.storageKey
    @AppStorage("artistAlbums.sortOrder") private var sortOrderStorage = ArtistAlbumSortOrder.ascending.storageKey
    @AppStorage("library.separateReleaseTypes") private var separateReleaseTypesEnabled = false
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false

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
        .task { await refresh() }
        .onAppear {
            // So "is this album fully downloaded" reads correctly offline even before any live
            // fetch has happened this session — guarded internally, cheap to call again.
            Task(priority: .utility) { await LibraryCacheStatus.shared.preload() }
        }
    }

    private var artistHeader: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(url: artworkURL, maxPixelSize: ImageCache.cardMaxPixelSize) { image in
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
            .frame(width: 120, height: 120)
            .clipShape(Circle())

            Text(artist.name)
                .font(.system(size: 28, weight: .bold))
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
        } else if separateReleaseTypesEnabled && hasMultipleReleaseTypes {
            releaseTypeCarousels
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(sortedAlbums) { album in
                    NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                        AlbumCardView(album: album, zoomNamespace: albumZoomNamespace, subtitle: .year)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable(album))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var displayAlbums: [AlbumID3] {
        var result = groupReleaseVersionsEnabled ? albums.groupedByPreferredVersion() : albums
        if !networkMonitor.isOnline, !showUnavailableInLists {
            result = result.filter {
                libraryCacheStatus.isAlbumFullyDownloaded(albumId: $0.id.raw, downloads: downloads)
            }
        }
        return result
    }

    private var sortedAlbums: [AlbumID3] {
        // Settings read once, outside the sort: each read builds a `Binding` and scans `allCases`,
        // which the old comparator did on every single comparison.
        let ascending = sortOrder.wrappedValue == .ascending
        switch sortField.wrappedValue {
        case .title:
            return displayAlbums.sortedByLocalizedKey(ascending: ascending) { $0.name.sortKey }
        case .year:
            return displayAlbums.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                return ascending ? lhsYear < rhsYear : lhsYear > rhsYear
            }
        }
    }

    private var hasMultipleReleaseTypes: Bool {
        Set(displayAlbums.map { ReleaseTypeCategory(rawTag: $0.releaseTypes?.first) }).count > 1
    }

    /// Buckets `sortedAlbums` by release type — each bucket keeps the current Title/Year +
    /// Ascending/Descending sort internally, but the rows themselves always appear in the fixed
    /// order `ReleaseTypeCategory.allCases` declares (Albums, EPs, Singles, Compilations, Live
    /// albums, Instrumentals, Other), regardless of the album sort setting.
    private var releaseTypeGroups: [(category: ReleaseTypeCategory, albums: [AlbumID3])] {
        let buckets = Dictionary(grouping: sortedAlbums, by: { ReleaseTypeCategory(rawTag: $0.releaseTypes?.first) })
        return ReleaseTypeCategory.allCases.compactMap { category in
            buckets[category].map { (category: category, albums: $0) }
        }
    }

    private var releaseTypeCarousels: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(releaseTypeGroups, id: \.category) { group in
                albumCarousel(title: group.category.rawValue, albums: group.albums)
            }
        }
        .padding(.top, 8)
    }

    /// Same carousel presentation as `AlbumView`'s "Other versions"/"More by artist" rows.
    private func albumCarousel(title: LocalizedStringKey, albums: [AlbumID3]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so only the cards actually scrolled into view build (and start loading
                // their artwork) — an eager `HStack` started every card's image load at once.
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                            AlbumCardView(album: album, zoomNamespace: albumZoomNamespace, subtitle: .year)
                                .frame(width: 160)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isAvailable(album))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Same expression `AlbumCardView` computes internally for its own dimming — this is the
    /// only way to also `.disabled(...)` the `NavigationLink` it's the label of.
    private func isAvailable(_ album: AlbumID3) -> Bool {
        networkMonitor.isOnline || downloads.hasDownloadedSong(inAlbum: album.id.raw)
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

    /// Runs from `.task`, which starts every time this screen becomes visible again — including
    /// when popping back from a pushed album. Only the very first load shows the spinner and
    /// replaces the grid; later runs refetch quietly and just update `albums` in place once done,
    /// so the grid's view identity (and the ScrollView's scroll position) stays stable instead of
    /// being torn down and rebuilt, which was also breaking the album's zoom-dismiss transition
    /// mid-animation. Mirrors `LibraryView.refresh()`.
    ///
    /// Stale-while-revalidate: shows this artist's cached albums immediately (no spinner) if any
    /// are cached, then revalidates against the server and only touches the displayed list if
    /// the fresh result actually differs from what's shown. Fetching, comparing and caching
    /// happen in `LibraryLoader`, off the main actor.
    private func refresh() async {
        guard client.isConfigured else {
            albums = []
            hasLoadedOnce = false
            return
        }
        if !hasLoadedOnce {
            isLoading = true
        }
        defer { isLoading = false }
        for await event in LibraryLoader.load(.artistAlbums(artistId: artist.id.raw), shown: albums) {
            switch event {
            case .cached(let cached):
                albums = cached
                hasLoadedOnce = true
                isLoading = false
            case .fresh(let fetched):
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
                albums = fetched
            case .upToDate:
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                isLoading = false
                if albums.isEmpty {
                    loadError = error.localizedDescription
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
            // Never queue up a song that's about to fail to stream with no network — see
            // `AlbumView.playableSongs`'s identical reasoning.
            let playableSongs = networkMonitor.isOnline ? songs : songs.filter { downloads.isDownloaded($0.id.raw) }
            await MainActor.run {
                isLoadingQueue = false
                let queue = transform(playableSongs)
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
