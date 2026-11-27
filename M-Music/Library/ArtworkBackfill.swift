import Foundation
import UIKit

/// Saves every list's row thumbnails to disk, quietly, so that scrolling a list never waits for
/// the server — over Wi-Fi only (see `NetworkMonitor.allowsBackgroundDownloads`).
///
/// What's saved is what the rows of Songs, Albums, Artists and Playlists ask for (a song's row,
/// its album's cover or its own art — see `ListArtwork`); nothing is decoded. It goes behind every
/// other download (`ArtworkDownloadQueue.Priority.bulk`), waits while a screen is scrolled, picks
/// up where it left off — whatever is saved is skipped — and gives up for now when the server
/// keeps failing. Anything that may have added to the library asks for a pass.
actor ArtworkBackfill {
    static let shared = ArtworkBackfill()

    /// How many thumbnails are downloaded at once.
    private static let parallelism = 2
    /// How many in a row may fail before the pass is given up.
    private static let failureLimit = 6

    private let cache: ImageCache
    private let isAllowed: @Sendable () -> Bool
    private let thumbnails: @Sendable () async -> [URL]
    private let delay: Duration

    private var pass: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var isRequested = false
    /// What couldn't be had since the app started: not tried again by every pass.
    private var failed: Set<URL> = []

    init(
        cache: ImageCache = .shared,
        isAllowed: @escaping @Sendable () -> Bool = { NetworkMonitor.shared.allowsBackgroundDownloads },
        thumbnails: @escaping @Sendable () async -> [URL] = { await ArtworkBackfill.libraryThumbnails() },
        delay: Duration = .seconds(5)
    ) {
        self.cache = cache
        self.isAllowed = isAllowed
        self.thumbnails = thumbnails
        self.delay = delay
    }

    /// Asks for a pass, run once things have been quiet for a moment.
    func request() {
        isRequested = true
        scheduled?.cancel()
        scheduled = Task(priority: .utility) { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.start()
        }
    }

    /// Stops: the app is going away, or the server has changed.
    func stop() {
        isRequested = false
        scheduled?.cancel()
        scheduled = nil
        pass?.cancel()
        pass = nil
    }

    /// Another server: what failed on the old one says nothing about this one.
    func reset() {
        stop()
        failed = []
    }

    /// Waits for the pass under way, for tests.
    func finish() async {
        await scheduled?.value
        await pass?.value
    }

    private func start() {
        guard isRequested, pass == nil, isAllowed() else { return }
        isRequested = false
        pass = Task(priority: .utility) {
            await self.run()
            self.ended()
        }
    }

    private func ended() {
        // Not for a pass `stop` has already put away.
        guard !Task.isCancelled else { return }
        pass = nil
        // Asked for again while this one ran: something may have been added meanwhile.
        if isRequested { start() }
    }

    private func run() async {
        let wanted = await thumbnails()
        var missing = wanted.filter { !failed.contains($0) && !cache.isSaved($0) }[...]
        var failuresInARow = 0
        while !missing.isEmpty, failuresInARow < Self.failureLimit {
            await ScrollActivity.shared.waitUntilIdle()
            guard !Task.isCancelled, isAllowed() else { return }
            let batch = Array(missing.prefix(Self.parallelism))
            missing = missing.dropFirst(batch.count)
            let cache = self.cache
            let results = await BoundedConcurrency.map(batch, limit: Self.parallelism) { url -> Bool in
                await cache.prefetchOriginalData(url, priority: .bulk)
                return cache.isSaved(url)
            }
            guard !Task.isCancelled else { return }
            for (url, saved) in zip(batch, results) {
                if saved {
                    failuresInARow = 0
                } else {
                    failed.insert(url)
                    failuresInARow += 1
                }
            }
        }
    }

    /// The thumbnails the lists of the cached library ask for.
    static func libraryThumbnails() async -> [URL] {
        guard SubsonicClient.shared.isConfigured else { return [] }
        let database = LibraryCacheDatabase.shared
        await ListArtwork.shared.prepare()
        let scale = await MainActor.run { UIScreen.main.scale }
        return requests(
            songs: await database.cachedAllSongs() ?? [],
            albums: await database.cachedAllAlbums() ?? [],
            artists: await database.cachedAllArtists() ?? [],
            playlists: await database.cachedAllPlaylists() ?? [],
            scale: scale,
            albumCoversOnSongs: ArtworkSettings.useAlbumCoverForSongs(),
            songArtwork: { ListArtwork.shared.artworkId(for: $0) }
        ).compactMap(\.url)
    }

    /// Each list's rows' requests, songs first, each image once. With album covers on song rows,
    /// every album's is wanted at their size — also before the song list has ever been fetched.
    static func requests(
        songs: [Child], albums: [AlbumID3], artists: [ArtistID3], playlists: [PlaylistSummary],
        scale: CGFloat, albumCoversOnSongs: Bool, songArtwork: (Child) -> String
    ) -> [ArtworkRequest] {
        var all = songs.map { ArtworkRequest.songRow(songArtwork($0), scale: scale) }
        if albumCoversOnSongs {
            all += albums.compactMap { album in album.coverArt.map { ArtworkRequest.songRow($0, scale: scale) } }
        }
        all += albums.map { ArtworkRequest.albumRow($0.coverArt ?? $0.id.raw, scale: scale) }
        all += artists.map { ArtworkRequest.artistRow($0.coverArt ?? $0.id.raw, scale: scale) }
        all += playlists.map { ArtworkRequest.playlistRow($0.coverArt ?? $0.id.raw, scale: scale) }
        var seen = Set<ArtworkRequest>()
        return all.filter { seen.insert($0).inserted }
    }
}
