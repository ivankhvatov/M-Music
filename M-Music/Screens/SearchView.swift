//
//  SearchView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

/// A screen a result opens.
private enum SearchRoute: Identifiable, Hashable {
    case artist(ArtistID3)
    case album(AlbumID3)
    case playlist(PlaylistSummary)

    var id: String {
        switch self {
        case .artist(let artist): "artist-\(artist.id.raw)"
        case .album(let album): "album-\(album.id.raw)"
        case .playlist(let playlist): "playlist-\(playlist.id.raw)"
        }
    }
}

/// What `SearchView` keeps about the rows on screen without being re-rendered by it — see
/// `LastSeenIndex`: the thumbnail of each row (for looking ahead and for `open`), and where each row
/// is. The rows are the search results, or the history while that is what's shown.
@MainActor
private final class SearchLookAhead {
    private var results = SearchOutcome(items: [], requests: [])
    private var history = SearchOutcome(items: [], requests: [])
    private var showsHistory = false
    private let positions = RowPositions()
    var lastIndex = 0

    var requests: [ArtworkRequest] { showsHistory ? history.requests : results.requests }

    func setResults(_ outcome: SearchOutcome) {
        results = outcome
        rebuild()
    }

    func setHistory(_ outcome: SearchOutcome) {
        history = outcome
        rebuild()
    }

    func setShowsHistory(_ shows: Bool) {
        guard shows != showsHistory else { return }
        showsHistory = shows
        rebuild()
    }

    private func rebuild() {
        positions.update(ids: (showsHistory ? history : results).items.map(\.id))
        lastIndex = 0
    }

    func position(of id: String) -> Int? { positions.position(of: id) }

    func request(ofID id: String) -> ArtworkRequest? {
        position(of: id).flatMap { requests.indices.contains($0) ? requests[$0] : nil }
    }
}

struct SearchView: View {
    @State var query = ""
    @AppStorage(SearchBarPosition.storageKey) private var searchBarPositionStorage = SearchBarPosition.top.stored

    @Namespace private var albumZoomNamespace
    @Namespace private var playlistZoomNamespace
    @Environment(\.displayScale) private var displayScale

    private let client = SubsonicClient.shared
    /// Not observed — see `SongsListView.player`.
    private let player = PlayerManager.shared

    /// The library and the search over it, off the main actor. A reference that is never read in
    /// `body`: the library arriving must not re-render the results.
    @State private var engine = SearchEngine()
    @State private var results: [SearchItem] = []
    /// What was opened or played from the results, shown while the field is open and empty.
    @State private var history: [SearchItem] = []
    /// Whether the search field is open (the keyboard is up) — see `SearchingReader`.
    @State private var isSearching = false
    /// The query `results` is for, so "no results" isn't shown for a query still being searched.
    @State private var settledQuery = ""
    @State private var lookAhead = SearchLookAhead()
    /// The screen being opened, once it's ready to be.
    @State private var route: SearchRoute?
    @State private var isOpening = false
    /// The search in flight, and which one is the newest.
    @State private var searchTask: Task<Void, Never>?
    @State private var historyTask: Task<Void, Never>?
    @State private var applyGeneration = 0

    /// Rows are a little taller than the library lists': more room around the same artwork.
    private let rowMinHeight: CGFloat = 56
    /// One artwork size for every kind of row, and one title and subtitle font (18 and 14pt).
    private let rowArtworkSize: CGFloat = 56
    private let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    /// What a very broad query is cut down to.
    private static let resultLimit = 300
    /// How long a burst of keystrokes is waited out before searching, and how long the matches of
    /// a list arriving are (four of them tend to arrive together).
    private static let typingDelay: Duration = .milliseconds(150)
    private static let loadDelay: Duration = .milliseconds(50)
    /// How long after a screen is popped the history waits before re-ordering itself: the pop's zoom
    /// lands on the row it left, which must not move meanwhile.
    private static let afterPopDelay: Duration = .milliseconds(900)

    private var searchBarPosition: SearchBarPosition {
        SearchBarPosition(stored: searchBarPositionStorage)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .modifier(SearchFieldModifier(text: $query, position: searchBarPosition))
                .screenOnStack()
                .navigationDestination(item: $route) { route in
                    switch route {
                    case .artist(let artist):
                        LazyDestination { ArtistAlbumsView(artist: artist) }
                    case .album(let album):
                        LazyDestination { AlbumView(album: album, zoomNamespace: albumZoomNamespace) }
                    case .playlist(let playlist):
                        LazyDestination { PlaylistView(playlist: playlist, zoomNamespace: playlistZoomNamespace) }
                    }
                }
                .toolbar {
                    filterButton
                    SettingsToolbarItem()
                }
                .task { await loadLibrary() }
                .task { await refreshHistory() }
                .onAppResume { warmAround(lookAhead.lastIndex) }
                .onChange(of: query) { search(after: Self.typingDelay) }
                .onChange(of: showsHistory) { lookAhead.setShowsHistory(showsHistory) }
                // The history is brought up to date while it isn't on screen, so it never reorders
                // under the user's finger: when the field closes, when the query is cleared (what
                // was opened meanwhile moves up), and a moment after a screen is popped.
                .onChange(of: isSearching) { if !isSearching { refreshHistory(after: .zero) } }
                .onChange(of: trimmedQuery.isEmpty) { if trimmedQuery.isEmpty { refreshHistory(after: .zero) } }
                .onChange(of: route) { if route == nil { refreshHistory(after: Self.afterPopDelay) } }
        }
        .environment(\.appTab, AppNavigation.searchTab)
        .environment(\.keepsSystemColorScheme, searchBarPosition == .bottom)
    }

    /// The list is always there, with the empty states drawn over it: swapping it out for them (and
    /// back) would tear down the rows, and the zoom transition's source with them.
    private var content: some View {
        List {
            if showsHistory {
                Section {
                    ForEach(history) { item in
                        row(for: item)
                            .listRowInsets(rowInsets)
                            .onAppear { warmAhead(after: item) }
                            .swipeActions {
                                Button(role: .destructive) {
                                    forget(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Recently Searched")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Clear") { clearHistory() }
                            .font(.subheadline)
                    }
                    .textCase(nil)
                }
            } else {
                ForEach(results) { item in
                    row(for: item)
                        .listRowInsets(rowInsets)
                        .onAppear { warmAhead(after: item) }
                }
            }
        }
        .listStyle(.plain)
        // Whether the field is open can only be read from inside what `searchable` is applied to.
        .background(SearchingReader(isSearching: $isSearching))
        // Which covers song results show has changed (see `ListArtwork`): what's warmed follows.
        .onReceive(NotificationCenter.default.publisher(for: ListArtwork.didChange)) { _ in
            if !isOpening, route == nil { search() }
        }
        // Background work holds off while the results are scrolled — see `ScrollActivity`.
        .onScrollPhaseChange { _, phase in
            ScrollActivity.shared.set(scrolling: phase != .idle)
        }
        .onDisappear { ScrollActivity.shared.set(scrolling: false) }
        .overlay {
            if results.isEmpty, !trimmedQuery.isEmpty, settledQuery == trimmedQuery {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    /// The history is shown while the field is open and empty. A screen being opened from it keeps
    /// it on screen — the field may close as the screen is pushed, and the row the zoom starts from
    /// must stay put.
    private var showsHistory: Bool {
        trimmedQuery.isEmpty && !history.isEmpty && (isSearching || isOpening || route != nil)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: SearchItem) -> some View {
        switch item {
        case .artist(let artist):
            // A plain push, like the Artists list.
            SearchResultLink(availability: .artist(name: artist.name), minHeight: rowMinHeight, onOpen: { open(.artist(artist)) }) {
                ArtistRow(artist: artist, subtitle: String(localized: "Artist"), artworkSize: rowArtworkSize, displayScale: displayScale)
            }

        case .album(let album):
            // Zooms out of the cover, and the album's own screen opens with its header decoded —
            // see `open`.
            SearchResultLink(availability: .album(id: album.id.raw), minHeight: rowMinHeight, onOpen: { open(.album(album)) }) {
                AlbumRow(
                    album: album, zoomNamespace: albumZoomNamespace,
                    subtitle: Self.subtitle(kind: Self.albumKind(album), by: album.artist),
                    artworkSize: rowArtworkSize,
                    displayScale: displayScale
                )
            }

        case .playlist(let playlist):
            SearchResultLink(availability: .playlist(id: playlist.id.raw), minHeight: rowMinHeight, onOpen: { open(.playlist(playlist)) }) {
                PlaylistRow(
                    playlist: playlist, zoomNamespace: playlistZoomNamespace,
                    subtitle: Self.subtitle(kind: String(localized: "Playlist"), by: playlist.owner),
                    artworkSize: rowArtworkSize,
                    displayScale: displayScale
                )
            }

        case .song(let song):
            SearchSongRow(
                track: song,
                subtitle: Self.subtitle(kind: String(localized: "Song"), by: song.artist),
                artworkSize: rowArtworkSize,
                displayScale: displayScale,
                minHeight: rowMinHeight,
                onPlay: { play(song) }
            )
        }
    }

    /// Pushes the screen — for an album or playlist, once its header image is decoded. The zoom
    /// needs the destination to be ready as it starts: a screen that has to decode its large cover
    /// first opens without the animation. The rows warm their destinations too, but only after
    /// staying on screen a moment, and a search's results are usually tapped sooner than that. Costs
    /// nothing when the image is already in memory.
    private func open(_ route: SearchRoute) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            // The header it opens with, and the row's own thumbnail it zooms out of.
            let thumbnail = lookAhead.request(ofID: route.id)
            switch route {
            case .artist:
                break
            case .album(let album):
                await ImageWarmer.shared.prepare([.albumHeader(album.coverArt ?? album.id.raw)] + [thumbnail].compactMap { $0 })
            case .playlist(let playlist):
                await ImageWarmer.shared.prepare([.playlistHeader(playlist.coverArt ?? playlist.id.raw)] + [thumbnail].compactMap { $0 })
            }
            remember(route.id)
            self.route = route
            isOpening = false
        }
    }

    /// "Album • Artist" — just the kind when there's no name to follow it.
    private static func subtitle(kind: String, by name: String?) -> String {
        guard let name, !name.isEmpty else { return kind }
        return "\(kind) • \(name)"
    }

    /// The album's release type ("EP", "Single", …), or plain "Album" without one.
    private static func albumKind(_ album: AlbumID3) -> String {
        let tag = album.releaseTypes?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch ReleaseTypeCategory(rawTag: tag) {
        case .album: return String(localized: "Album")
        case .ep: return String(localized: "EP")
        case .single: return String(localized: "Single")
        case .compilation: return String(localized: "Compilation")
        case .liveAlbum: return String(localized: "Live album")
        case .instrumental: return String(localized: "Instrumental")
        case .other: return tag.isEmpty ? String(localized: "Album") : tag.capitalized
        }
    }

    /// Replaces the queue with just this song.
    private func play(_ song: Child) {
        player.play(queue: [song], startAt: 0, origin: .other)
        remember(SearchItem.song(song).id)
    }

    // MARK: - History

    /// Adds what was opened or played to the history. It isn't shown again until the history is next
    /// brought up to date (see `body`).
    private func remember(_ id: String) {
        Task { await SearchHistoryStore.shared.record(id) }
    }

    private func forget(_ item: SearchItem) {
        history.removeAll { $0.id == item.id }
        let id = item.id
        Task { await SearchHistoryStore.shared.remove(id) }
    }

    private func clearHistory() {
        history = []
        Task { await SearchHistoryStore.shared.clear() }
    }

    /// Reads the history again — after `delay`, and only the newest such request counts — and shows
    /// it once its first thumbnails are in memory, like the results (see `show`).
    private func refreshHistory(after delay: Duration) {
        historyTask?.cancel()
        historyTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await refreshHistory()
        }
    }

    private func refreshHistory() async {
        let scale = displayScale
        let points = rowArtworkSize
        let ids = await SearchHistoryStore.shared.recent()
        let outcome = await engine.items(matching: ids, scale: scale, artworkPoints: points)
        guard !Task.isCancelled else { return }
        await prepareFirst(of: outcome.requests)
        // Never while it's on screen and a screen is being opened from it.
        guard !Task.isCancelled, !isOpening, route == nil else { return }
        lookAhead.setHistory(outcome)
        history = outcome.items
        warmAround(0)
    }

    // MARK: - Searching

    /// Searches the library for the query, after `delay` (a burst of keystrokes is coalesced into
    /// the last one) — the newest search wins. The matching itself is `SearchEngine`'s, off the main
    /// actor; this task only waits for it and then for the first rows' thumbnails.
    private func search(after delay: Duration? = nil) {
        searchTask?.cancel()
        applyGeneration += 1
        let generation = applyGeneration
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = []
            settledQuery = ""
            return
        }
        let scale = displayScale
        let points = rowArtworkSize
        let engine = engine
        searchTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let outcome = await engine.search(text, limit: Self.resultLimit, scale: scale, artworkPoints: points),
                  !Task.isCancelled else { return }
            await show(outcome, for: text, generation: generation)
        }
    }

    /// Puts `outcome` on screen once the thumbnails of its first rows are in memory — rows that
    /// appear with placeholders and fill in as they load keep the screen busy, and a tap during that
    /// opens the album without its zoom. Usually there's nothing to wait for (they're cached, which
    /// is found out synchronously, as in `ImageReadiness.require`); otherwise it gives up waiting
    /// after a moment. What's further down is warmed once the rows are shown (`warmAhead`).
    private func show(_ outcome: SearchOutcome, for text: String, generation: Int) async {
        await prepareFirst(of: outcome.requests)
        // Not while an album is being opened: rebuilding the rows would pull the zoom's source out
        // from under it.
        guard generation == applyGeneration, !isOpening, route == nil else { return }
        lookAhead.setResults(outcome)
        results = outcome.items
        settledQuery = text
        warmAround(0)
    }

    /// Waits for the thumbnails of the first rows to be in memory — usually there's nothing to wait
    /// for (they're cached, which is found out synchronously, as in `ImageReadiness.require`);
    /// otherwise it gives up after a moment.
    private func prepareFirst(of requests: [ArtworkRequest]) async {
        let first = Array(requests.prefix(ImageWarmer.gateLimit + 4))
        if !first.allSatisfy({ ImageCache.shared.isCached($0) }) {
            await ImageWarmer.shared.prepare(first, timeout: .milliseconds(800))
        }
    }

    // MARK: - Look-ahead

    /// A row scrolled into view: warm the ones around it, so a fast scroll finds them ready.
    private func warmAhead(after item: SearchItem) {
        guard let index = lookAhead.position(of: item.id) else { return }
        lookAhead.lastIndex = index
        warmAround(index)
    }

    /// Warms the thumbnails around `index` — also after the app resumes, where the user left off.
    private func warmAround(_ index: Int) {
        let requests = lookAhead.requests
        guard requests.indices.contains(index) else { return }
        let near = ImageWarmer.neighbors(of: index, in: requests, count: ImageWarmer.scrollAheadCount)
        Task { await ImageWarmer.shared.warmAhead(near, source: "search") }
    }

    // MARK: - Loading

    /// The four lists the search runs over, each from the cache first, then revalidated — the same
    /// way their own screens load them, so it works offline too. They load alongside each other,
    /// off the main actor; each one that changed what's indexed has the matches refreshed (once for
    /// the lists that arrive together).
    private func loadLibrary() async {
        guard client.isConfigured else { return }
        let engine = engine
        let refresh: @MainActor @Sendable () -> Void = {
            search(after: Self.loadDelay)
            refreshHistory(after: Self.loadDelay)
        }
        async let artists: Void = Self.load(.allArtists(), current: { await engine.artists }, apply: { await engine.update(artists: $0) }, refresh: refresh)
        async let albums: Void = Self.load(.allAlbums(), current: { await engine.albums }, apply: { await engine.update(albums: $0) }, refresh: refresh)
        async let playlists: Void = Self.load(.allPlaylists(), current: { await engine.playlists }, apply: { await engine.update(playlists: $0) }, refresh: refresh)
        async let songs: Void = Self.load(.allSongs(), current: { await engine.songs }, apply: { await engine.update(songs: $0) }, refresh: refresh)
        _ = await (artists, albums, playlists, songs)
    }

    /// Feeds one list from `LibraryLoader` into the engine. Everything but `refresh` runs off the
    /// main actor.
    private nonisolated static func load<Value: Equatable & Sendable>(
        _ source: LibrarySource<Value>,
        current: @Sendable () async -> Value,
        apply: @Sendable (Value) async -> Bool,
        refresh: @MainActor @Sendable () -> Void
    ) async {
        for await event in LibraryLoader.load(source, shown: await current()) {
            switch event {
            case .cached(let value), .fresh(let value):
                if await apply(value) { await refresh() }
            case .upToDate, .failed:
                break
            }
        }
    }

    @ToolbarContentBuilder
    private var filterButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {} label: {
                Image(systemName: "line.horizontal.3.decrease")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// Puts the search field where the user chose (`SearchBarPosition`).
private struct SearchFieldModifier: ViewModifier {
    @Binding var text: String
    let position: SearchBarPosition

    @ViewBuilder
    func body(content: Content) -> some View {
        switch position {
        case .top:
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        case .bottom:
            content.searchable(text: $text, placement: .toolbar, prompt: "Search")
        }
    }
}

/// Reports whether the search field is open into `isSearching`. `\.isSearching` is only set for the
/// views inside what `searchable` is applied to, so it's read here, in a view placed there.
private struct SearchingReader: View {
    @Binding var isSearching: Bool
    @Environment(\.isSearching) private var environmentIsSearching

    var body: some View {
        Color.clear
            .onChange(of: environmentIsSearching, initial: true) { isSearching = environmentIsSearching }
    }
}

/// What decides whether a result is available while offline: a downloaded song of the artist, of
/// the album, in the playlist, or the song itself. The same checks the Artists, Albums, Playlists
/// and Songs lists make to dim and disable a row.
private enum SearchAvailability {
    case artist(name: String)
    case album(id: String)
    case playlist(id: String)
    case song(id: String)
}

/// Builds `content` with whether the result is available. Online, everything is, and the only thing
/// observed is the network flag — which changes rarely; the download and library-cache stores, which
/// change often, are only observed by a row that is offline (`OfflineAvailability`). `SearchView`
/// observes none of them: every change (a cached album detail being written while an album opens,
/// say) would rebuild all of the rows, the zoom transition's source among them.
private struct AvailabilityGate<Content: View>: View {
    let availability: SearchAvailability
    @ViewBuilder let content: (Bool) -> Content

    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        if networkMonitor.isOnline {
            content(true)
        } else {
            OfflineAvailability(availability: availability, content: content)
        }
    }
}

private struct OfflineAvailability<Content: View>: View {
    let availability: SearchAvailability
    @ViewBuilder let content: (Bool) -> Content

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared

    private var isAvailable: Bool {
        switch availability {
        case .artist(let name):
            return downloads.hasDownloadedSong(byArtist: name)
        case .album(let id):
            return downloads.hasDownloadedSong(inAlbum: id)
        case .playlist(let id):
            let songIds = libraryCacheStatus.songIds(forPlaylist: id) ?? []
            return songIds.contains { downloads.isDownloaded($0) }
        case .song(let id):
            return downloads.isDownloaded(id)
        }
    }

    var body: some View {
        content(isAvailable)
    }
}

/// A row of the results that opens a screen: its content and the trailing chevron a `NavigationLink`
/// would have drawn — it's a button because the screen is only pushed once `SearchView.open` has it
/// ready.
private struct SearchResultLink<Label: View>: View {
    let availability: SearchAvailability
    let minHeight: CGFloat
    let onOpen: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        AvailabilityGate(availability: availability) { isAvailable in
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
        }
    }
}

/// A song's row in the search results: tapping it plays it; the ellipsis menu is `SongRow`'s, as in
/// the songs list.
private struct SearchSongRow: View {
    let track: Child
    let subtitle: String
    let artworkSize: CGFloat
    let displayScale: CGFloat
    let minHeight: CGFloat
    let onPlay: () -> Void

    var body: some View {
        AvailabilityGate(availability: .song(id: track.id.raw)) { isAvailable in
            Button(action: onPlay) {
                SongRow(
                    track: track, rowArtworkSize: artworkSize, displayScale: displayScale,
                    showsGoToActions: true, showsAddToPlaylist: true, subtitle: subtitle
                )
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
        }
    }
}

#Preview {
    SearchView()
}
