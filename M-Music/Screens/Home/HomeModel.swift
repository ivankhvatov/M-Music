import Foundation

/// One card of a Home carousel — everything the card view needs as plain values, built off the main
/// actor. Two cards are equal when what they *show* is: the album or playlist itself (needed to
/// open it) isn't compared, so SwiftUI can tell cheaply that a card didn't change.
struct HomeCard: Identifiable, Equatable, Sendable {
    enum Content: Sendable {
        case album(AlbumID3)
        case playlist(PlaylistSummary)
    }

    /// The album's or playlist's id.
    let id: String
    /// Its position in its carousel.
    let index: Int
    let routeID: FlexibleID
    let content: Content
    let title: String
    let subtitle: String
    let request: ArtworkRequest
    let artworkURL: URL?
    let isAvailable: Bool

    static func == (lhs: HomeCard, rhs: HomeCard) -> Bool {
        lhs.id == rhs.id && lhs.index == rhs.index && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.request == rhs.request && lhs.isAvailable == rhs.isAvailable
    }

    init(album: AlbumID3, index: Int, isAvailable: Bool) {
        let request = ArtworkRequest.albumCard(album.coverArt ?? album.id.raw)
        self.id = album.id.raw
        self.index = index
        self.routeID = album.id
        self.content = .album(album)
        self.title = album.name + (album.version != nil ? (" (" + album.version! + ")") : "")
        self.subtitle = album.artist ?? "Unknown Artist"
        self.request = request
        self.artworkURL = request.url
        self.isAvailable = isAvailable
    }

    init(playlist: PlaylistSummary, index: Int, isAvailable: Bool) {
        let request = ArtworkRequest.playlistCard(playlist.coverArt ?? playlist.id.raw)
        self.id = playlist.id.raw
        self.index = index
        self.routeID = playlist.id
        self.content = .playlist(playlist)
        self.title = playlist.name
        self.subtitle = playlist.owner ?? "Unknown Creator"
        self.request = request
        self.artworkURL = request.url
        self.isAvailable = isAvailable
    }
}

/// One carousel on Home.
struct HomeCarouselModel: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case kind(HomeCarouselKind)
        case verbatim(String)
    }

    let kind: HomeCarouselKind
    let title: Title
    /// Names the carousel's look-ahead queue in `ImageWarmer` (and is its identity).
    let source: String
    let cards: [HomeCard]

    var id: String { source }
}

/// Everything Home shows, in order — a pure value, built off the main actor by `HomeLayoutBuilder`,
/// so the view's `body` is just a loop over it.
struct HomeLayout: Equatable, Sendable {
    var carousels: [HomeCarouselModel] = []

    static let empty = HomeLayout()

    /// The covers of the first `perCarousel` cards of each carousel, in display order, up to `limit`.
    func requests(perCarousel: Int, limit: Int, where include: (HomeCarouselModel) -> Bool = { _ in true }) -> [ArtworkRequest] {
        var result: [ArtworkRequest] = []
        for carousel in carousels where include(carousel) {
            result += carousel.cards.prefix(perCarousel).map(\.request)
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    /// What the first frame waits for.
    var firstScreenRequests: [ArtworkRequest] {
        requests(perCarousel: HomeLoadingPolicy.cardsPerCarousel, limit: ImageWarmer.gateLimit)
    }

    /// The covers worth remembering for the next launch or resume: only the carousels that stay the
    /// same (the random, favorite-artist and genre picks change on every load).
    var rememberedRequests: [ArtworkRequest] {
        requests(perCarousel: 4, limit: ImageWarmer.manifestLimit) {
            $0.kind != .randomAlbums && $0.kind != .favoriteArtistAlbums && $0.kind != .randomGenres
        }
    }
}

/// How many of Home's carousels are built, growing from the first screenful so that building them
/// all is spread over a second instead of stalling the moment Home appears.
enum HomeReveal {
    /// What the first screen shows.
    static let initialCount = 3
    static let step = 2
    static let interval: Duration = .milliseconds(80)

    static func next(_ current: Int, total: Int) -> Int {
        min(max(total, 0), current + step)
    }

    /// A count never beyond what exists.
    static func clamped(_ current: Int, total: Int) -> Int {
        min(max(current, 0), max(total, 0))
    }
}

/// Which albums and playlists are available offline. Empty while online, where everything is: so
/// downloads changing while online changes nothing, and no card has to be re-rendered for it.
struct HomeAvailability: Equatable, Sendable {
    var isOnline = true
    var albumIdsWithDownloads: Set<String> = []
    var playlistIdsWithDownloads: Set<String> = []

    static let online = HomeAvailability()

    func isAvailable(albumId: String) -> Bool { isOnline || albumIdsWithDownloads.contains(albumId) }
    func isAvailable(playlistId: String) -> Bool { isOnline || playlistIdsWithDownloads.contains(playlistId) }
}

enum HomeAvailabilityLoader {
    /// The availability for the current connectivity, read off the main actor: the downloaded
    /// albums from the download database, the playlists containing a downloaded song from the
    /// library cache.
    static func load(isOnline: Bool) async -> HomeAvailability {
        guard !isOnline else { return .online }
        let records = await DownloadDatabase.shared.allRecords()
        let albumIds = Set(records.compactMap(\.albumId))
        let songIds = Set(records.map(\.songId))
        let playlistIds = songIds.isEmpty ? [] : await LibraryCacheDatabase.shared.playlistIds(containingAnyOf: songIds)
        return HomeAvailability(isOnline: false, albumIdsWithDownloads: albumIds, playlistIdsWithDownloads: playlistIds)
    }
}

enum HomeLayoutBuilder {
    /// Turns the settings and the loaded data into the layout: which carousels, in what order, with
    /// which cards — what `HomeView.body` used to work out on every evaluation.
    static func build(
        order: String,
        disabled: String,
        randomGenreCount: Int,
        genreTitles: [String: String] = [:],
        sections: HomeAlbumSections,
        recentlyPlayed: [AlbumID3],
        topPlaylists: [PlaylistSummary],
        availability: HomeAvailability
    ) -> HomeLayout {
        func albumCards(_ albums: [AlbumID3]) -> [HomeCard] {
            albums.enumerated().map { index, album in
                HomeCard(album: album, index: index, isAvailable: availability.isAvailable(albumId: album.id.raw))
            }
        }
        var carousels: [HomeCarouselModel] = []
        func add(_ kind: HomeCarouselKind, title: HomeCarouselModel.Title, source: String, cards: [HomeCard]) {
            guard !cards.isEmpty else { return }
            carousels.append(HomeCarouselModel(kind: kind, title: title, source: source, cards: cards))
        }

        for kind in HomeContentSettings.visible(order: order, disabled: disabled, randomGenreCount: randomGenreCount) {
            switch kind {
            case .topPlaylists:
                let cards = topPlaylists.enumerated().map { index, playlist in
                    HomeCard(
                        playlist: playlist, index: index,
                        isAvailable: availability.isAvailable(playlistId: playlist.id.raw)
                    )
                }
                add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: cards)
            case .randomGenres:
                for genre in sections.genres.prefix(randomGenreCount) {
                    add(kind, title: .verbatim(genreTitles[genre.name] ?? genre.name), source: "home.genre.\(genre.id)", cards: albumCards(genre.albums))
                }
            case .randomAlbums: add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: albumCards(sections.random))
            case .latestReleases: add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: albumCards(sections.latestReleases))
            case .recentlyAdded: add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: albumCards(sections.recentlyAdded))
            case .recentlyPlayed: add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: albumCards(recentlyPlayed))
            case .favoriteArtistAlbums:
                add(kind, title: .kind(kind), source: "home.\(kind.rawValue)", cards: albumCards(sections.favoriteArtists))
            }
        }
        return HomeLayout(carousels: carousels)
    }
}
