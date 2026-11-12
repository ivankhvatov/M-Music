import SwiftUI
import Observation

/// A screen opened from outside the tabs' own screens — from the expanded player's menu, or a song
/// row's. Holds the ids only: the screens fetch what they show when they appear, so the player can collapse
/// and the push begin right away.
enum AppRoute: Hashable {
    case album(id: String)
    /// The album artist of an album.
    case artist(ofAlbum: String)
    /// An artist, by their own id.
    case artistWithID(String)
}

/// Which of the screens a route leads to a screen on a tab's stack is. Only for these screens: the
/// others are never what a route leads to, so nothing needs to know them apart.
enum ScreenKey: Hashable {
    case album(String)
    /// By the artist's own id.
    case artist(String)
}

/// A screen on a tab's stack, as `AppNavigation` knows it — see `View.screenOnStack()`.
final class ScreenToken {
    /// Which screen it is, when it's one a route can lead to.
    var key: ScreenKey?
}

/// A route to be pushed, on top of what's on the tab's stack.
struct PushRequest: Equatable {
    let id: Int
    let tab: Int
    let route: AppRoute
}

/// Which tab is showing, and where the app has been asked to go — held here, rather than in the
/// views, so that the player's menu can send the app somewhere.
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    static let homeTab = 0
    static let radioTab = 1
    static let libraryTab = 2
    static let searchTab = 3

    var selectedTab = AppNavigation.homeTab
    /// The screen the app is asked to push, until the screen on top of the tab's stack has taken it.
    private(set) var request: PushRequest?
    private var requestCount = 0

    /// What's on each tab's stack, bottom to top, as the screens report it (`ScreenHost`). Held
    /// weakly: a screen that has been popped is gone from it by itself.
    @ObservationIgnored private var stacks: [[WeakScreen]] = Array(repeating: [], count: 4)

    private struct WeakScreen {
        weak var token: ScreenToken?
    }

    private var openTask: Task<Void, Never>?

    /// What the screens `open` is taking the app to show, found ahead of the push, so that they
    /// arrive in it instead of after it: built a moment into the transition, they were a second
    /// redraw on top of it.
    private(set) var albums: [String: AlbumID3] = [:]
    private(set) var artists: [String: ArtistID3] = [:]
    private(set) var artistsByID: [String: ArtistID3] = [:]

    /// Takes the app to `route` in the tab that is open: the menu it was chosen from goes first,
    /// then the player collapses, then — once that has settled — the screen is pushed on top of
    /// whatever is open there, or, if that is the screen already, nothing more is done. Each is an
    /// animation that keeps the CPU busy for as long as it lasts, and they were far costlier run
    /// together than one after another. What the screen shows is looked up meanwhile.
    ///
    /// `fromPlayer`: whether the menu is the expanded player's. Chosen from a screen's own song
    /// row there is no player to collapse, and the screen is pushed once the menu has gone.
    func open(_ route: AppRoute, fromPlayer: Bool = true) {
        openTask?.cancel()
        let tab = selectedTab
        openTask = Task { @MainActor in
            async let lookup: Void = prefetch(route)
            try? await Task.sleep(for: .seconds(Self.menuDismissal))
            guard !Task.isCancelled else { return }
            if fromPlayer {
                PlayerPresentation.shared.collapse()
                await PlayerPresentation.shared.waitUntilCollapsed()
                try? await Task.sleep(for: .seconds(Self.collapseSettling))
            }
            await lookup
            guard !Task.isCancelled else { return }
            if let key = key(of: route), topScreenKey(inTab: tab) == key { return }
            requestCount += 1
            request = PushRequest(id: requestCount, tab: tab, route: route)
        }
    }

    /// Which screen `route` leads to. The artist's, for the album artist of an album, is only known
    /// once it's been looked up.
    private func key(of route: AppRoute) -> ScreenKey? {
        switch route {
        case .album(let id): .album(id)
        case .artist(let albumID): artists[albumID].map { .artist($0.id.raw) }
        case .artistWithID(let id): .artist(id)
        }
    }

    // MARK: - The screens on the stacks

    func screenAppeared(_ token: ScreenToken, tab: Int) {
        guard stacks.indices.contains(tab) else { return }
        stacks[tab].removeAll { $0.token == nil || $0.token === token }
        stacks[tab].append(WeakScreen(token: token))
    }

    func screenDisappeared(_ token: ScreenToken, tab: Int) {
        guard stacks.indices.contains(tab) else { return }
        stacks[tab].removeAll { $0.token == nil || $0.token === token }
    }

    func isTopScreen(_ token: ScreenToken, tab: Int) -> Bool {
        stacks.indices.contains(tab) && stacks[tab].last(where: { $0.token != nil })?.token === token
    }

    private func topScreenKey(inTab tab: Int) -> ScreenKey? {
        guard stacks.indices.contains(tab) else { return nil }
        return stacks[tab].last(where: { $0.token != nil })?.token?.key
    }

    /// The screen on top has taken `request` and is pushing it.
    func consume(_ request: PushRequest) {
        if self.request == request { self.request = nil }
    }

    private func prefetch(_ route: AppRoute) async {
        switch route {
        case .album(let id):
            if let detail = await RouteLookup.albumDetail(id: id) { albums[id] = AlbumID3(detail) }
        case .artist(let albumID):
            if let artist = await RouteLookup.albumArtist(ofAlbum: albumID) { artists[albumID] = artist }
        case .artistWithID(let id):
            if let artist = await RouteLookup.artist(id: id) { artistsByID[id] = artist }
        }
    }

    /// How long the menu takes to go away after a button in it is chosen.
    private static let menuDismissal = 0.3
    /// How long after the collapse has settled the screen it leaves is still being redrawn.
    private static let collapseSettling = 0.3
}

extension EnvironmentValues {
    /// The tab whose stack a screen is on, set on each tab's `NavigationStack`; -1 outside them.
    @Entry var appTab = -1
    /// The screen's own entry in `AppNavigation`'s view of its tab's stack (see `screenOnStack`).
    @Entry var screenToken: ScreenToken?
}

extension View {
    /// Makes this a screen on its tab's stack that `AppNavigation` knows of — the root of a tab, or
    /// a screen pushed on it, by a link or by a route. The one that's on top is the one that pushes
    /// what the player's menu asks for, so that it arrives on top of whatever is open, however it
    /// got there: pushed from a typed path of its own, a route took the place of the screens the
    /// links had pushed.
    func screenOnStack() -> some View {
        modifier(ScreenHost())
    }
}

private struct ScreenHost: ViewModifier {
    @Environment(\.appTab) private var tab
    @State private var token = ScreenToken()
    @State private var pushed: AppRoute?
    private let navigation = AppNavigation.shared

    func body(content: Content) -> some View {
        content
            .environment(\.screenToken, token)
            .onAppear {
                navigation.screenAppeared(token, tab: tab)
                take(navigation.request)
            }
            .onDisappear { navigation.screenDisappeared(token, tab: tab) }
            .onChange(of: navigation.request) { _, request in take(request) }
            .navigationDestination(item: $pushed) { route in
                switch route {
                case .album(let id): RoutedAlbumView(id: id)
                case .artist(let albumID): RoutedArtistView(albumID: albumID)
                case .artistWithID(let id): RoutedArtistView(artistID: id)
                }
            }
    }

    /// Pushes the route asked for, if this is the screen on top of the stack it's asked for in.
    private func take(_ request: PushRequest?) {
        guard let request, request.tab == tab, navigation.isTopScreen(token, tab: tab) else { return }
        navigation.consume(request)
        pushed = request.route
    }
}

extension AppRoute {
    /// The symbol for going to an artist. It's new in the 2026 release; before it, the same glyph
    /// is `music.mic` (of which the new name is an alias).
    static let artistSymbol = UIImage(systemName: "microphone.dynamic.on.stand") != nil
        ? "microphone.dynamic.on.stand" : "music.mic"
}

/// An album opened by id: the album's own screen once it's been found — in the cache, or on the
/// server.
struct RoutedAlbumView: View {
    let id: String
    @State private var album: AlbumID3?
    @State private var failed = false

    init(id: String) {
        self.id = id
        _album = State(initialValue: AppNavigation.shared.albums[id])
    }

    var body: some View {
        Group {
            if let album {
                AlbumView(album: album)
            } else if failed {
                ContentUnavailableView("Album not available", systemImage: "opticaldisc")
            } else {
                ProgressView()
            }
        }
        .screenOnStack()
        .task {
            guard album == nil else { return }
            if let detail = await RouteLookup.albumDetail(id: id) {
                album = AlbumID3(detail)
            } else {
                failed = true
            }
        }
    }
}

/// An artist's screen, opened by the artist's id — or, for the album artist of an album, by the
/// album's.
struct RoutedArtistView: View {
    private enum Source {
        case albumArtist(ofAlbum: String)
        case artist(id: String)
    }

    private let source: Source
    @State private var artist: ArtistID3?
    @State private var failed = false

    init(albumID: String) {
        source = .albumArtist(ofAlbum: albumID)
        _artist = State(initialValue: AppNavigation.shared.artists[albumID])
    }

    init(artistID: String) {
        source = .artist(id: artistID)
        _artist = State(initialValue: AppNavigation.shared.artistsByID[artistID])
    }

    var body: some View {
        Group {
            if let artist {
                ArtistAlbumsView(artist: artist)
            } else if failed {
                ContentUnavailableView("Artist not available", systemImage: AppRoute.artistSymbol)
            } else {
                ProgressView()
            }
        }
        .screenOnStack()
        .task {
            guard artist == nil else { return }
            let found: ArtistID3?
            switch source {
            case .albumArtist(let albumID): found = await RouteLookup.albumArtist(ofAlbum: albumID)
            case .artist(let id): found = await RouteLookup.artist(id: id)
            }
            if let found {
                artist = found
            } else {
                failed = true
            }
        }
    }
}

private enum RouteLookup {
    /// Cached first — works offline too, and is instant — then the server.
    static func albumDetail(id: String) async -> AlbumWithSongsID3? {
        if let cached = await LibraryCacheDatabase.shared.cachedAlbumSongs(albumId: id) { return cached }
        return try? await SubsonicClient.shared.getAlbum(id: id)
    }

    /// Cached first, like `albumDetail` — works offline too, and is instant — then the server.
    static func artist(id artistID: String) async -> ArtistID3? {
        if let cached = await LibraryCacheDatabase.shared.cachedAllArtists()?.first(where: { $0.id.raw == artistID }) {
            return cached
        }
        guard let found = try? await SubsonicClient.shared.getArtist(id: artistID) else { return nil }
        return ArtistID3(
            id: found.id, name: found.name, coverArt: found.coverArt,
            albumCount: found.albumCount, starred: found.starred, userRating: found.userRating
        )
    }

    static func albumArtist(ofAlbum albumID: String) async -> ArtistID3? {
        guard let album = await albumDetail(id: albumID), let artistID = album.artistId?.raw else { return nil }
        if let found = try? await SubsonicClient.shared.getArtist(id: artistID) {
            return ArtistID3(
                id: found.id, name: found.name, coverArt: found.coverArt,
                albumCount: found.albumCount, starred: found.starred, userRating: found.userRating
            )
        }
        // Offline: what the album knows of its artist is enough to open the screen.
        guard let name = album.artist else { return nil }
        return ArtistID3(id: FlexibleID(artistID), name: name, coverArt: nil, albumCount: nil, starred: nil, userRating: nil)
    }
}

private extension AlbumID3 {
    init(_ detail: AlbumWithSongsID3) {
        self.init(
            id: detail.id, name: detail.name, artist: detail.artist, artistId: detail.artistId,
            coverArt: detail.coverArt, songCount: detail.songCount, duration: detail.duration,
            playCount: detail.playCount, created: detail.created, starred: detail.starred,
            year: detail.year, genre: detail.genre, userRating: detail.userRating,
            recordLabels: detail.recordLabels, releaseTypes: detail.releaseTypes, version: detail.version
        )
    }
}
