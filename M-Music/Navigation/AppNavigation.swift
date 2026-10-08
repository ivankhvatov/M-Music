import SwiftUI
import Observation

/// A screen opened from outside the tabs' own screens — from the expanded player's menu. Holds
/// the ids only: the screens fetch what they show when they appear, so the player can collapse
/// and the push begin right away.
enum AppRoute: Hashable {
    case album(id: String)
    /// The album artist of an album.
    case artist(ofAlbum: String)
}

/// Which tab is showing and what's pushed on each tab's stack — held here, rather than in the
/// views, so that the player's menu can send the app somewhere.
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    static let homeTab = 0
    static let radioTab = 1
    static let libraryTab = 2
    static let searchTab = 3

    var selectedTab = AppNavigation.homeTab
    /// The routes pushed on each tab, on top of whatever its own links have pushed.
    var paths: [[AppRoute]] = Array(repeating: [], count: 4)

    private var openTask: Task<Void, Never>?

    /// What the screens `open` is taking the app to show, found ahead of the push, so that they
    /// arrive in it instead of after it: built a moment into the transition, they were a second
    /// redraw on top of it.
    private(set) var albums: [String: AlbumID3] = [:]
    private(set) var artists: [String: ArtistID3] = [:]

    /// Takes the app to `route` in the tab that is open: the menu it was chosen from goes first,
    /// then the player collapses, then — once that has settled — the screen is pushed. Each is an
    /// animation that keeps the CPU busy for as long as it lasts, and they were far costlier
    /// run together than one after another. What the screen shows is looked up meanwhile.
    func open(_ route: AppRoute) {
        openTask?.cancel()
        let tab = selectedTab
        openTask = Task { @MainActor in
            async let lookup: Void = prefetch(route)
            try? await Task.sleep(for: .seconds(Self.menuDismissal))
            guard !Task.isCancelled else { return }
            PlayerPresentation.shared.collapse()
            await PlayerPresentation.shared.waitUntilCollapsed()
            try? await Task.sleep(for: .seconds(Self.collapseSettling))
            await lookup
            guard !Task.isCancelled else { return }
            paths[tab].append(route)
        }
    }

    private func prefetch(_ route: AppRoute) async {
        switch route {
        case .album(let id):
            if let detail = await RouteLookup.albumDetail(id: id) { albums[id] = AlbumID3(detail) }
        case .artist(let albumID):
            if let artist = await RouteLookup.albumArtist(ofAlbum: albumID) { artists[albumID] = artist }
        }
    }

    /// How long the menu takes to go away after a button in it is chosen.
    private static let menuDismissal = 0.3
    /// How long after the collapse has settled the screen it leaves is still being redrawn.
    private static let collapseSettling = 0.3
}

extension View {
    /// What a tab's stack shows for the routes `AppNavigation` pushes onto it.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .album(let id): RoutedAlbumView(id: id)
            case .artist(let albumID): RoutedArtistView(albumID: albumID)
            }
        }
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

/// The album artist of an album, opened by the album's id.
struct RoutedArtistView: View {
    let albumID: String
    @State private var artist: ArtistID3?
    @State private var failed = false

    init(albumID: String) {
        self.albumID = albumID
        _artist = State(initialValue: AppNavigation.shared.artists[albumID])
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
        .task {
            guard artist == nil else { return }
            if let found = await RouteLookup.albumArtist(ofAlbum: albumID) {
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
