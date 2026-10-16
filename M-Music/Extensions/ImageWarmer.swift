import Foundation
import Observation
import UIKit

/// Decodes the images a screen is about to show into `ImageCache`'s memory layer *before* the
/// screen opens, so it comes up with its artwork on the first frame instead of placeholders that
/// fill in one by one.
///
/// iOS empties that memory layer while the app is in the background, so after every launch and
/// most resumes the first visit to each screen would otherwise decode everything on demand —
/// behind the per-cell load delay and the serialized decode gate. Two things warm it ahead of time:
///
/// - **Launch and resume** (`warmAll`): the Now Playing artwork, then the first screenful of each
///   library screen. Rather than predicting what a sorted, filtered, 16,000-item list will show
///   first (which would mean sorting it at launch), every list records the requests it actually
///   displayed first (`remember`), and those are warmed next time.
/// - **Look-ahead** (`warmAlbum`, `warmPlaylist`, `warmArtist`): a row or card that's been on
///   screen for a moment warms the screen it leads to — its large header image and what that
///   screen lists — so the push lands on finished artwork.
///
/// Nothing here delays or blocks navigation: if a warm-up hasn't finished by the time a screen
/// opens, the screen just loads as it always did. It all runs at utility priority through
/// `ImageCache.preload`, which paces decodes (one at a time, with a pause) so warming never
/// competes with scrolling or an animation for CPU, and never goes to the network for bulk lists.
actor ImageWarmer {
    static let shared = ImageWarmer()

    /// A screen that records what it shows first.
    enum Screen: String, CaseIterable, Sendable {
        case home, library, albums, playlists, artists, songs
    }

    /// How many of a screen's first requests are remembered (and warmed): a screenful and a bit.
    static let manifestLimit = 24
    /// How long a row/card must stay on screen before it warms its destination, so a fast scroll
    /// doesn't decode a header for every row it flies past.
    static let lookAheadDelay: Duration = .milliseconds(300)
    /// How many of a list's first requests it waits for before showing its content: about what
    /// fits on a screen.
    static let gateLimit = 12
    /// How many rows below the one that just scrolled into view are warmed (see `warmAhead`).
    static let scrollAheadCount = 24
    /// How many of a destination's own items (an artist's albums, a playlist's songs) are warmed.
    static let destinationItemLimit = 12

    private let defaults: UserDefaults
    private let cache: ImageCache
    private let scaleProvider: @Sendable () async -> CGFloat

    private var warmPass: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    /// The warm-up of each screen's newly changed first screenful (see `remember`).
    private var refreshTasks: [Screen: Task<Void, Never>] = [:]
    /// Destinations already warmed since the memory layer was last (possibly) emptied.
    private var warmedDestinations: Set<String> = []

    init(
        defaults: UserDefaults = .standard,
        cache: ImageCache = .shared,
        scale: @escaping @Sendable () async -> CGFloat = { await MainActor.run { UIScreen.main.scale } }
    ) {
        self.defaults = defaults
        self.cache = cache
        self.scaleProvider = scale
    }

    // MARK: - Manifests

    private static func manifestKey(_ screen: Screen) -> String { "ImageWarmer.manifest.\(screen.rawValue)" }

    /// Records the first requests `screen` displayed, to warm them after the next launch. When
    /// they differ from what was recorded — the user picked another sort order or filter, so a
    /// different set of items is now first — they're also warmed right away, so the re-sorted list
    /// doesn't come up with placeholders where its new first items are.
    func remember(_ screen: Screen, _ requests: [ArtworkRequest]) {
        let limited = Array(requests.prefix(Self.manifestLimit))
        guard limited != manifest(for: screen) else { return }
        if let data = try? JSONEncoder().encode(limited) {
            defaults.set(data, forKey: Self.manifestKey(screen))
        }
        refreshTasks[screen]?.cancel()
        refreshTasks[screen] = Task(priority: .utility) { [cache] in
            for request in limited {
                guard !Task.isCancelled else { return }
                await cache.preload(request)
            }
        }
    }

    func manifest(for screen: Screen) -> [ArtworkRequest] {
        guard let data = defaults.data(forKey: Self.manifestKey(screen)) else { return [] }
        return (try? JSONDecoder().decode([ArtworkRequest].self, from: data)) ?? []
    }

    // MARK: - Launch and resume

    /// Warms Now Playing first (`nowPlaying`, with the queue's tracks around the current one),
    /// then every screen's remembered first screenful. A pass already running is replaced: it's
    /// only ever called for a launch or a resume, and the newer one skips what's already decoded.
    func warmAll(nowPlayingURL: URL?, upcoming: [Child]) {
        warmPass?.cancel()
        // The memory layer may have been emptied since the last pass, so what was warmed for
        // destinations is no longer necessarily there.
        warmedDestinations.removeAll()
        warmPass = Task(priority: .utility) { [self] in
            await warmNowPlaying(url: nowPlayingURL, upcoming: upcoming)
            for screen in Screen.allCases {
                for request in manifest(for: screen) {
                    guard !Task.isCancelled else { return }
                    await cache.preload(request)
                }
            }
        }
    }

    /// The memory layer was emptied (a memory warning): what was warmed for destinations may be
    /// gone, so the next row to ask warms its destination again.
    func memoryWasPurged() {
        warmedDestinations.removeAll()
    }

    /// Stops a warm-up in progress (the app went to the background).
    func cancel() {
        warmPass?.cancel()
        warmPass = nil
    }

    // MARK: - Now Playing

    /// The expanded player's artwork (full resolution), the colour-sampling thumbnail its gradient
    /// is built from, and the thumbnails of the queue rows listed beneath it.
    func warmNowPlaying(url: URL?, upcoming: [Child]) async {
        if let url {
            // Not bulk, and the player is what the user sees first: fetching it is fine.
            await cache.preload(url, maxPixelSize: nil, allowNetwork: true)
            await cache.preload(url, maxPixelSize: ImageCache.colorSamplingMaxPixelSize, allowNetwork: true)
        }
        guard !upcoming.isEmpty else { return }
        let scale = await scaleProvider()
        for track in upcoming.prefix(Self.destinationItemLimit) {
            guard !Task.isCancelled else { return }
            await cache.preload(.songRow(ArtworkRequest.artworkId(of: track), scale: scale))
        }
    }

    // MARK: - Opening a screen

    /// Gets `requests` into memory as fast as it sensibly can, for a screen that's open and holding
    /// its content back until they are (`ImageReadiness`): the bytes of whatever isn't on disk
    /// are fetched a few at a time, then everything is decoded without the warm-up pauses. Gives
    /// up after `timeout` — a slow or unreachable server must never keep a list blank.
    func prepare(_ requests: [ArtworkRequest], timeout: Duration = .seconds(2)) async {
        let cache = self.cache
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { downloads in
                    for request in requests where !cache.isCached(request) {
                        downloads.addTask { await cache.prefetchOriginalData(request.url) }
                    }
                }
                for request in requests {
                    guard !Task.isCancelled else { return }
                    await cache.preload(request, allowNetwork: true, paced: false)
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Scrolling

    /// Warms the images of the rows just below one that scrolled into view, so a fast scroll
    /// finds them already decoded instead of starting each load as its row appears. Only the
    /// latest request counts — a newer row appearing replaces the previous one, which is by then
    /// further up the list. Fetches whatever isn't on disk, a few at a time, then decodes.
    func warmAhead(_ requests: [ArtworkRequest]) {
        scrollTask?.cancel()
        let cache = self.cache
        scrollTask = Task(priority: .userInitiated) {
            let missing = requests.filter { !cache.isCached($0) }
            guard !missing.isEmpty else { return }
            await withTaskGroup(of: Void.self) { downloads in
                for request in missing { downloads.addTask { await cache.prefetchOriginalData(request.url) } }
            }
            for request in missing {
                guard !Task.isCancelled else { return }
                await cache.preload(request, allowNetwork: true)
            }
        }
    }

    // MARK: - Look-ahead

    /// Warms the album screen `artworkId` leads to: its header image.
    func warmAlbum(id: String, artworkId: String) async {
        await warmOnce("album:\(id)") {
            await cache.preload(.albumHeader(artworkId))
        }
    }

    /// Warms the playlist screen: its header image and the thumbnails of its first songs (read
    /// from the cached playlist, so nothing here waits on the server).
    func warmPlaylist(id: String, artworkId: String) async {
        await warmOnce("playlist:\(id)") {
            await cache.preload(.playlistHeader(artworkId))
            guard let songs = await LibraryCacheDatabase.shared.cachedPlaylistSongs(playlistId: id) else { return }
            let scale = await scaleProvider()
            for song in songs.prefix(Self.destinationItemLimit) {
                guard !Task.isCancelled else { return }
                await cache.preload(.songRow(ArtworkRequest.artworkId(of: song), scale: scale))
            }
        }
    }

    /// Warms the artist screen: its header picture and the cards of its first albums (from the
    /// cached album list).
    func warmArtist(id: String, artworkId: String) async {
        await warmOnce("artist:\(id)") {
            await cache.preload(.artistHeader(artworkId))
            guard let albums = await LibraryCacheDatabase.shared.cachedArtistAlbums(artistId: id) else { return }
            // The covers that will really be first on that screen, in the user's selected order
            // (sort field and order, grouped versions, separate release types) — not the first
            // ones in the order the server listed them.
            let first = ArtistAlbumOrdering.firstScreenful(
                of: albums, settings: .stored(in: defaults), limit: Self.destinationItemLimit
            )
            for album in first {
                guard !Task.isCancelled else { return }
                await cache.preload(.albumCard(album.coverArt ?? album.id.raw))
            }
        }
    }

    /// Runs `work` for a destination that hasn't been warmed yet — after waiting out
    /// `lookAheadDelay` (cancelled with the row that asked) — and marks it warmed only if it
    /// wasn't cancelled part-way.
    private func warmOnce(_ key: String, _ work: () async -> Void) async {
        guard !warmedDestinations.contains(key) else { return }
        try? await Task.sleep(for: Self.lookAheadDelay)
        guard !Task.isCancelled else { return }
        await work()
        guard !Task.isCancelled else { return }
        warmedDestinations.insert(key)
    }
}

/// Holds a list screen's content back until the images of its first screenful are in memory, so
/// the list comes up with its artwork instead of placeholders.
///
/// Usually there's nothing to wait for — the launch warm-up (or an earlier visit) already decoded
/// them, `require` finds that out synchronously, and the content is never hidden. Only a screen
/// opened before its images are ready shows its loading state for the moment `ImageWarmer.prepare`
/// takes (at most its timeout). Applies to the screen's first display only: later changes (a new
/// sort order, a search) are warmed ahead by `ImageWarmer.remember` and never hide what's on screen.
@MainActor
@Observable
final class ImageReadiness {
    private(set) var isReady = false
    private var isPreparing = false

    /// Marks the content ready if `requests`' images are all in memory; otherwise starts getting
    /// them there, and marks it ready when that's done.
    func require(_ requests: [ArtworkRequest]) {
        guard !isReady, !isPreparing else { return }
        let needed = Array(requests.prefix(ImageWarmer.gateLimit))
        if needed.allSatisfy({ ImageCache.shared.isCached($0) }) {
            isReady = true
            return
        }
        isPreparing = true
        Task {
            await ImageWarmer.shared.prepare(needed)
            isPreparing = false
            isReady = true
        }
    }
}

/// Where each row of a list screen sits, so the row that just appeared can warm the ones below it
/// (`ImageWarmer.warmAhead`) without searching the whole list for itself. Rebuilt whenever the
/// screen's displayed items change.
@MainActor
final class RowPositions {
    private var positions: [String: Int] = [:]

    func update(ids: [String]) {
        positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func position(of id: String) -> Int? { positions[id] }
}
