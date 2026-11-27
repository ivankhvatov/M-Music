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
    /// More than a Home carousel holds (20), so the first card to appear queues the whole carousel.
    static let scrollAheadCount = 40
    /// Up to `count` items around `index`, nearest first, alternating after and before it. A
    /// scrolling list or carousel needs the items on *both* sides warm: the ones ahead of the
    /// scroll, and — after the cache was emptied while the app was away — the ones it scrolls back
    /// to, which a look-ahead that only looks forward leaves cold.
    static func neighbors<Element>(of index: Int, in items: [Element], count: Int) -> [Element] {
        guard items.indices.contains(index) else { return [] }
        var result: [Element] = []
        var step = 1
        while result.count < count, index + step < items.count || index - step >= 0 {
            if index + step < items.count { result.append(items[index + step]) }
            if result.count < count, index - step >= 0 { result.append(items[index - step]) }
            step += 1
        }
        return result
    }

    /// How many cards around the one that appeared a carousel warms: about eight screens-worth on
    /// each side is more than a swipe covers before the next card has asked again.
    static let carouselAheadCount = 16
    /// How many covers of each neighbouring Home carousel are warmed before it's reached.
    static let neighborCarouselCards = 8
    /// How many of a destination's own items (an artist's albums, a playlist's songs) are warmed.
    static let destinationItemLimit = 12

    private let defaults: UserDefaults
    private let cache: ImageCache
    private let scaleProvider: @Sendable () async -> CGFloat

    private var warmPass: Task<Void, Never>?
    private struct AheadLoad {
        let id: Int
        let task: Task<Void, Never>
    }
    /// Each look-ahead source's loads under way — see `warmAhead`.
    private var aheadLoads: [String: [Target: AheadLoad]] = [:]
    /// When a look-ahead's image last couldn't be had.
    private var failedAhead: [Target: ContinuousClock.Instant] = [:]
    private static let retryDelay: Duration = .seconds(30)
    private static let failureLimit = 500
    /// How many loads `warmAhead` has started, for tests.
    private(set) var aheadLoadsStarted = 0
    /// Each list's `warmWholeList` under way.
    private var wholeListPasses: [String: Task<Void, Never>] = [:]
    /// The most distinct thumbnails a list may have for all of them to be decoded: at a song row's
    /// size, some 40 MB.
    static let wholeListLimit = 600
    private static let wholeListParallelism = 3
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
        failedAhead.removeAll()
    }

    /// Stops a warm-up in progress (the app went to the background).
    func cancel() {
        warmPass?.cancel()
        warmPass = nil
        for loads in aheadLoads.values {
            for load in loads.values { load.task.cancel() }
        }
        aheadLoads.removeAll()
        failedAhead.removeAll()
        for pass in wholeListPasses.values { pass.cancel() }
        wholeListPasses.removeAll()
    }

    // MARK: - Now Playing

    /// The expanded player's artwork, the colour-sampling thumbnail its gradient is built from,
    /// and the thumbnails of the queue rows listed beneath it.
    func warmNowPlaying(url: URL?, upcoming: [Child]) async {
        if let url {
            // Not bulk, and the player is what the user sees first: fetching it is fine.
            await cache.preload(url, maxPixelSize: ImageCache.nowPlayingMaxPixelSize, allowNetwork: true)
            await cache.preload(url, maxPixelSize: ImageCache.colorSamplingMaxPixelSize, allowNetwork: true)
        }
        guard !upcoming.isEmpty else { return }
        let scale = await scaleProvider()
        for track in upcoming.prefix(Self.destinationItemLimit) {
            guard !Task.isCancelled else { return }
            await cache.preload(.songRow(ListArtwork.shared.artworkId(for: track), scale: scale))
        }
    }

    // MARK: - Opening a screen

    /// Gets `requests` into memory as fast as it sensibly can, for a screen that's open and holding
    /// its content back until they are (`ImageReadiness`): each image that isn't on disk is
    /// fetched — ahead of any look-ahead fetches — and decoded as soon as its bytes are there,
    /// without the warm-up pauses and as many at once as the cache allows. Returns after `timeout`
    /// at the latest — a slow or unreachable server must never keep a list blank — and at once if
    /// the caller is cancelled. What isn't done at the time limit carries on by itself, for the
    /// cells that will join it. `screen` only names the caller in the timing log (`PerfLog`).
    func prepare(_ requests: [ArtworkRequest], timeout: Duration = .seconds(2), screen: String = #fileID) async {
        let targets = requests.compactMap { request in
            request.url.map { Target(url: $0, maxPixelSize: request.maxPixelSize) }
        }
        await prepare(targets: targets, timeout: timeout, screen: screen)
    }

    func prepare(targets: [Target], timeout: Duration, screen: String = #fileID) async {
        let cache = self.cache
        let logWaitEnd = PerfLog.beginCoversWait(
            screen: screen, count: targets.count,
            missing: targets.filter { cache.image(for: $0.url, maxPixelSize: $0.maxPixelSize) == nil }.count,
            limit: timeout
        )
        defer { logWaitEnd() }
        // Ends when the work is done or the time is up, whichever is first. Not a task group:
        // one waits for all of its children, and a download that's under way can't be cancelled,
        // so the time limit held nothing to account.
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask {
                        if cache.image(for: target.url, maxPixelSize: target.maxPixelSize) != nil { return }
                        await cache.prefetchOriginalData(target.url, priority: .visible)
                        // A screen is waiting on these: ahead of any warm-up in the decode queue.
                        await cache.preload(
                            target.url, maxPixelSize: target.maxPixelSize, allowNetwork: true,
                            paced: false, priority: .interactive
                        )
                    }
                }
            }
            end.finish()
        }
        let timeLimit = Task {
            try? await Task.sleep(for: timeout)
            end.finish()
        }
        for await _ in ended {}
        timeLimit.cancel()
        if Task.isCancelled { work.cancel() }
    }

    // MARK: - Scrolling

    /// Warms the images of the rows or cards about to scroll into view, so a fast scroll finds them
    /// already decoded instead of starting each load as its row appears.
    ///
    /// Each `source` (a carousel, a list) has loads of its own. A call says what that source wants
    /// now, the most wanted first: loads of what it no longer wants are cancelled (a download that
    /// hasn't started is dropped — see `ArtworkDownloadQueue`), the ones still wanted carry on and
    /// the new ones start. Each image is decoded as soon as its bytes are there, during the scroll
    /// too: the download queue decides what comes first, and the cache's decode gate bounds the CPU.
    func warmAhead(_ requests: [ArtworkRequest], source: String) {
        warmAhead(targets: requests.compactMap { request in
            request.url.map { Target(url: $0, maxPixelSize: request.maxPixelSize) }
        }, source: source)
    }

    /// One image to decode: a URL and the tier it's shown at.
    struct Target: Sendable, Hashable {
        let url: URL
        let maxPixelSize: Int?
    }

    func warmAhead(targets: [Target], source: String) {
        var loads = aheadLoads[source] ?? [:]
        let wanted = Set(targets)
        for (target, load) in loads where !wanted.contains(target) {
            load.task.cancel()
            loads[target] = nil
        }
        let now = ContinuousClock.now
        for target in targets {
            guard loads[target] == nil, cache.image(for: target.url, maxPixelSize: target.maxPixelSize) == nil
            else { continue }
            // One that couldn't be had isn't asked for again by every row that scrolls past it.
            if let failed = failedAhead[target], now - failed < Self.retryDelay { continue }
            aheadLoadsStarted += 1
            let id = aheadLoadsStarted
            let task = Task(priority: .userInitiated) { [cache] in
                let loaded = await cache.preload(
                    target.url, maxPixelSize: target.maxPixelSize, allowNetwork: true,
                    paced: false, priority: .prefetch
                )
                self.finishedAhead(target, source: source, id: id, loaded: loaded)
            }
            loads[target] = AheadLoad(id: id, task: task)
        }
        aheadLoads[source] = loads
    }

    /// Decodes every one of a list's thumbnails behind whatever the screen and the scroll want, if
    /// there are few enough of them (`wholeListLimit`) — however fast the list is then scrolled, nothing is
    /// left to load. With album covers on song rows (`ListArtwork`), a library of thousands of
    /// songs has only a few hundred. `requests` is worked out here, off the main actor. A new call
    /// for the same `source` replaces the one under way.
    func warmWholeList(source: String, requests: @Sendable @escaping () -> [ArtworkRequest]) {
        warmWholeList(source: source, targets: {
            var seen = Set<ArtworkRequest>()
            let distinct = requests().filter { seen.insert($0).inserted }
            // Too many: not worth signing thousands of URLs to find that out below.
            guard distinct.count <= Self.wholeListLimit else { return [] }
            return distinct.compactMap { request in
                request.url.map { Target(url: $0, maxPixelSize: request.maxPixelSize) }
            }
        })
    }

    func warmWholeList(source: String, targets: @Sendable @escaping () -> [Target]) {
        wholeListPasses[source]?.cancel()
        wholeListPasses[source] = Task(priority: .utility) { [cache] in
            var seen = Set<Target>()
            let distinct = targets().filter { seen.insert($0).inserted }
            guard distinct.count <= Self.wholeListLimit, !Task.isCancelled else { return }
            _ = await BoundedConcurrency.map(distinct, limit: Self.wholeListParallelism) { target -> Bool in
                await cache.preload(
                    target.url, maxPixelSize: target.maxPixelSize, allowNetwork: true, paced: false, priority: .list
                )
            }
        }
    }

    private func finishedAhead(_ target: Target, source: String, id: Int, loaded: Bool) {
        // Not one that has been cancelled, or replaced since.
        guard aheadLoads[source]?[target]?.id == id else { return }
        aheadLoads[source]?[target] = nil
        if loaded {
            failedAhead[target] = nil
        } else {
            if failedAhead.count >= Self.failureLimit { failedAhead.removeAll() }
            failedAhead[target] = .now
        }
    }

    // MARK: - Look-ahead

    /// Warms the album screen `artworkId` leads to: its header image.
    func warmAlbum(id: String, artworkId: String) async {
        await warmOnce("album:\(id)") {
            await cache.prefetchOriginalData(ArtworkRequest.albumHeader(artworkId).url)
            await cache.preload(.albumHeader(artworkId))
        }
    }

    /// Warms the playlist screen: its header image and the thumbnails of its first songs (read
    /// from the cached playlist, so nothing here waits on the server).
    func warmPlaylist(id: String, artworkId: String) async {
        await warmOnce("playlist:\(id)") {
            await cache.prefetchOriginalData(ArtworkRequest.playlistHeader(artworkId).url)
            await cache.preload(.playlistHeader(artworkId))
            guard let songs = await LibraryCacheDatabase.shared.cachedPlaylistSongs(playlistId: id) else { return }
            let scale = await scaleProvider()
            for song in songs.prefix(Self.destinationItemLimit) {
                guard !Task.isCancelled else { return }
                await cache.preload(.songRow(ListArtwork.shared.artworkId(for: song), scale: scale))
            }
        }
    }

    /// Warms the artist screen: its header picture and the cards of its first albums (from the
    /// cached album list).
    func warmArtist(id: String, artworkId: String) async {
        await warmOnce("artist:\(id)") {
            await cache.prefetchOriginalData(ArtworkRequest.artistHeader(artworkId).url)
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
    func require(_ requests: [ArtworkRequest], screen: String = #fileID) {
        guard !isReady, !isPreparing else { return }
        let needed = Array(requests.prefix(ImageWarmer.gateLimit))
        if needed.allSatisfy({ ImageCache.shared.isCached($0) }) {
            isReady = true
            PerfLog.coversReady(screen: screen, count: needed.count)
            return
        }
        isPreparing = true
        Task {
            await ImageWarmer.shared.prepare(needed, screen: screen)
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
