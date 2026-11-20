//
//  SearchView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

/// One match in the library search: an artist, an album, a playlist or a song.
private enum SearchItem: Identifiable, Sendable {
    case artist(ArtistID3)
    case album(AlbumID3)
    case playlist(PlaylistSummary)
    case song(Child)

    var id: String {
        switch self {
        case .artist(let artist): "artist-\(artist.id.raw)"
        case .album(let album): "album-\(album.id.raw)"
        case .playlist(let playlist): "playlist-\(playlist.id.raw)"
        case .song(let song): "song-\(song.id.raw)"
        }
    }

    /// Where the kind sorts among equally good matches.
    var kindRank: Int {
        switch self {
        case .artist: 0
        case .album: 1
        case .playlist: 2
        case .song: 3
        }
    }
}

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

struct SearchView: View {
    @State var query = ""
    @AppStorage(SearchBarPosition.storageKey) private var searchBarPositionStorage = SearchBarPosition.top.stored

    @Namespace private var albumZoomNamespace
    @Namespace private var playlistZoomNamespace
    @Environment(\.displayScale) private var displayScale

    private let client = SubsonicClient.shared
    private let player = PlayerManager.shared

    @State private var artists: [ArtistID3] = []
    @State private var albums: [AlbumID3] = []
    @State private var playlists: [PlaylistSummary] = []
    @State private var songs: [Child] = []
    @State private var results: [SearchItem] = []
    /// The screen being opened, once it's ready to be.
    @State private var route: SearchRoute?
    @State private var isOpening = false
    /// Which call of `show` is the newest.
    @State private var applyGeneration = 0
    /// Matches off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()

    /// Rows are a little taller than the library lists': more room around the same artwork.
    private let rowMinHeight: CGFloat = 56
    /// One artwork size for every kind of row, and one title and subtitle font (18 and 14pt).
    private let rowArtworkSize: CGFloat = 56
    private let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    /// What a very broad query is cut down to.
    private nonisolated static let resultLimit = 300

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
                // A burst of keystrokes coalesces into one pass (the delay is inside `recompute`).
                .onChange(of: query) { recompute(debounced: true) }
        }
        .environment(\.appTab, AppNavigation.searchTab)
        .environment(\.keepsSystemColorScheme, searchBarPosition == .bottom)
    }

    /// The list is always there, with the empty states drawn over it: swapping it out for them (and
    /// back) would tear down the rows, and the zoom transition's source with them.
    private var content: some View {
        List {
            ForEach(results) { item in
                row(for: item)
                    .listRowInsets(rowInsets)
            }
        }
        .listStyle(.plain)
        .overlay {
            if !trimmedQuery.isEmpty, results.isEmpty, !deriver.isPending {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
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
            switch route {
            case .artist:
                break
            case .album(let album):
                await ImageWarmer.shared.prepare([
                    .albumHeader(album.coverArt ?? album.id.raw), artworkRequest(for: .album(album))
                ])
            case .playlist(let playlist):
                await ImageWarmer.shared.prepare([
                    .playlistHeader(playlist.coverArt ?? playlist.id.raw), artworkRequest(for: .playlist(playlist))
                ])
            }
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
    }

    // MARK: - Matching

    private struct Library: Sendable {
        var artists: [ArtistID3]
        var albums: [AlbumID3]
        var playlists: [PlaylistSummary]
        var songs: [Child]
    }

    private func recompute(debounced: Bool = false) {
        let search = trimmedQuery
        guard !search.isEmpty else {
            deriver.cancel()
            applyGeneration += 1
            results = []
            return
        }
        let library = Library(artists: artists, albums: albums, playlists: playlists, songs: songs)
        deriver.run(delay: debounced ? .milliseconds(200) : nil, {
            Self.matches(for: search, in: library)
        }, apply: { matches in
            show(matches)
        })
    }

    /// Puts `matches` on screen once the thumbnails of the first rows are in memory — rows that
    /// appear with placeholders and fill in as they load keep the screen busy, and a tap during that
    /// opens the album without its zoom. Gives up waiting after a moment; a newer result replaces
    /// this one meanwhile. Whatever is further down is warmed after it's shown.
    private func show(_ matches: [SearchItem]) {
        applyGeneration += 1
        let generation = applyGeneration
        let first = matches.prefix(ImageWarmer.gateLimit + 4).map(artworkRequest(for:))
        let rest = matches.dropFirst(ImageWarmer.gateLimit + 4).prefix(ImageWarmer.scrollAheadCount).map(artworkRequest(for:))
        Task {
            await ImageWarmer.shared.prepare(first, timeout: .milliseconds(800))
            // Not while an album is being opened: rebuilding the rows would pull the zoom's source
            // out from under it.
            guard generation == applyGeneration, !isOpening, route == nil else { return }
            results = matches
            await ImageWarmer.shared.warmAhead(rest, source: "search")
        }
    }

    /// The thumbnail a result's row shows.
    private func artworkRequest(for item: SearchItem) -> ArtworkRequest {
        switch item {
        case .artist(let artist):
            .artistRow(artist.coverArt ?? artist.id.raw, scale: displayScale, points: rowArtworkSize)
        case .album(let album):
            .albumRow(album.coverArt ?? album.id.raw, scale: displayScale, points: rowArtworkSize)
        case .playlist(let playlist):
            .playlistRow(playlist.coverArt ?? playlist.id.raw, scale: displayScale, points: rowArtworkSize)
        case .song(let song):
            .songRow(ArtworkRequest.artworkId(of: song), scale: displayScale, points: rowArtworkSize)
        }
    }

    /// Everything that matches, best first: a name that starts with the query, then one that
    /// contains it, then an item only its artist matches. Within those, artists, albums, playlists
    /// and songs in that order, each in the library's own order.
    private nonisolated static func matches(for search: String, in library: Library) -> [SearchItem] {
        func score(_ name: String, other: String? = nil) -> Int? {
            if name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 0 }
            if name.localizedCaseInsensitiveContains(search) { return 1 }
            if let other, other.localizedCaseInsensitiveContains(search) { return 2 }
            return nil
        }

        var scored: [(score: Int, item: SearchItem)] = []
        for artist in library.artists {
            if let s = score(artist.name) { scored.append((s, .artist(artist))) }
        }
        for album in library.albums {
            if let s = score(album.name, other: album.artist) { scored.append((s, .album(album))) }
        }
        for playlist in library.playlists {
            if let s = score(playlist.name, other: playlist.owner) { scored.append((s, .playlist(playlist))) }
        }
        for song in library.songs {
            if let s = score(song.title, other: song.artist) { scored.append((s, .song(song))) }
        }

        // A stable order: the sort isn't promised to be, so the position breaks ties.
        let ordered = scored.enumerated().sorted { lhs, rhs in
            if lhs.element.score != rhs.element.score { return lhs.element.score < rhs.element.score }
            if lhs.element.item.kindRank != rhs.element.item.kindRank {
                return lhs.element.item.kindRank < rhs.element.item.kindRank
            }
            return lhs.offset < rhs.offset
        }
        return ordered.prefix(resultLimit).map(\.element.item)
    }

    // MARK: - Loading

    /// The four lists the search runs over, each from the cache first, then revalidated — the same
    /// way their own screens load them, so it works offline too. All of them are loaded alongside
    /// each other; the matches are refreshed as each arrives.
    private func loadLibrary() async {
        guard client.isConfigured else { return }
        async let loadedArtists: Void = load(.allArtists(), shown: { artists }) { artists = $0 }
        async let loadedAlbums: Void = load(.allAlbums(), shown: { albums }) { albums = $0 }
        async let loadedPlaylists: Void = load(.allPlaylists(), shown: { playlists }) { playlists = $0 }
        async let loadedSongs: Void = load(.allSongs(), shown: { songs }) { songs = $0 }
        _ = await (loadedArtists, loadedAlbums, loadedPlaylists, loadedSongs)
    }

    private func load<Value: Equatable & Sendable>(
        _ source: LibrarySource<Value>,
        shown: () -> Value,
        assign: (Value) -> Void
    ) async {
        for await event in LibraryLoader.load(source, shown: shown()) {
            switch event {
            case .cached(let value), .fresh(let value):
                assign(value)
                recompute()
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

/// A row of the results that opens a screen: its content and the trailing chevron a `NavigationLink`
/// would have drawn — it's a button because the screen is only pushed once `SearchView.open` has it
/// ready. Observes download and network state itself, to disable itself while offline and not
/// downloaded: `SearchView` observes none of it, or every change to it (a cached album detail being
/// written while an album opens, say) would rebuild all of the rows, the zoom transition's source
/// among them.
private struct SearchResultLink<Label: View>: View {
    enum Availability {
        case artist(name: String)
        case album(id: String)
        case playlist(id: String)
    }

    let availability: Availability
    let minHeight: CGFloat
    let onOpen: () -> Void
    @ViewBuilder let label: Label

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared

    /// The same checks the Artists, Albums and Playlists lists make to dim and disable a row.
    private var isAvailable: Bool {
        guard !networkMonitor.isOnline else { return true }
        switch availability {
        case .artist(let name):
            return downloads.hasDownloadedSong(byArtist: name)
        case .album(let id):
            return downloads.hasDownloadedSong(inAlbum: id)
        case .playlist(let id):
            let songIds = libraryCacheStatus.songIds(forPlaylist: id) ?? []
            return songIds.contains { downloads.isDownloaded($0) }
        }
    }

    var body: some View {
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

/// A song's row in the search results: tapping it plays it; the ellipsis menu is `SongRow`'s, as in
/// the songs list. Observes download and network state itself, to disable itself — like the songs
/// list's rows.
private struct SearchSongRow: View {
    let track: Child
    let subtitle: String
    let artworkSize: CGFloat
    let displayScale: CGFloat
    let minHeight: CGFloat
    let onPlay: () -> Void

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        Button(action: onPlay) {
            SongRow(
                track: track, rowArtworkSize: artworkSize, displayScale: displayScale,
                showsGoToActions: true, showsAddToPlaylist: true, subtitle: subtitle
            )
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
    }
}

#Preview {
    SearchView()
}
