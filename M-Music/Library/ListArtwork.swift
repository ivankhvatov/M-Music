import Foundation
import Observation

/// Which picture a song's row in a list is shown with.
///
/// Navidrome gives every song with embedded art a cover id of its own, so a list of thousands of
/// songs asked the server for thousands of images, nearly all of them copies of an album's cover.
/// With "Use album cover for songs" on (`ArtworkSettings`), a row shows its album's cover instead:
/// one image, shared by all of the album's songs.
///
/// Which cover an album has comes from the album lists the app fetches (`LibraryCacheDatabase`
/// passes them on as it caches them). A song whose album isn't known keeps its own artwork id —
/// an album's is never guessed. Readable from any thread. A view that reads
/// `ListArtworkChanges.revision` in its `body` redraws when the answers change, and whoever works
/// out artwork requests ahead of time listens for `didChange`.
final class ListArtwork: @unchecked Sendable {
    static let shared = ListArtwork(onChange: {
        // Downloaded music keeps the covers its rows show — see `DownloadedArtwork` — and the
        // rest of the library's are saved ahead (`ArtworkBackfill`).
        Task {
            await DownloadedArtwork.shared.requestSync()
            await ArtworkBackfill.shared.request()
        }
    })

    /// Posted on the main actor after the answers have changed.
    static let didChange = Notification.Name("ListArtwork.didChange")

    typealias Catalog = @Sendable () async -> [AlbumID3]?

    private let lock = NSLock()
    private var usesAlbumCover: Bool
    private var coverByAlbumId: [String: String] = [:]
    /// Whether the whole album catalogue has been taken in, so `prepare` has nothing to do.
    private var hasCatalog = false
    private var loading: Task<Void, Never>?
    private var announcementPending = false

    private let defaults: UserDefaults
    private let cachedCatalog: Catalog
    private let fetchedCatalog: Catalog
    private let announceDelay: Duration
    private let onChange: @Sendable () -> Void

    init(
        defaults: UserDefaults = .standard,
        cachedCatalog: @escaping Catalog = { await LibraryCacheDatabase.shared.cachedAllAlbums() },
        fetchedCatalog: @escaping Catalog = { await ListArtwork.fetchCatalog() },
        announceDelay: Duration = .milliseconds(300),
        onChange: @escaping @Sendable () -> Void = {}
    ) {
        self.defaults = defaults
        self.cachedCatalog = cachedCatalog
        self.fetchedCatalog = fetchedCatalog
        self.announceDelay = announceDelay
        self.onChange = onChange
        self.usesAlbumCover = ArtworkSettings.useAlbumCoverForSongs(defaults)
    }

    /// The id the row of `track` requests its artwork by.
    func artworkId(for track: Child) -> String {
        let albumCover = lock.withLock {
            usesAlbumCover ? track.albumId.flatMap { coverByAlbumId[$0.raw] } : nil
        }
        return albumCover ?? ArtworkRequest.artworkId(of: track)
    }

    /// The cover id of an album, if one is known — whatever the preference.
    func cover(ofAlbum albumId: String) -> String? {
        lock.withLock { coverByAlbumId[albumId] }
    }

    // MARK: - Filling the map

    /// Takes in the covers an album list names. `isWholeCatalog`: it's every album there is, so
    /// ones it doesn't name are forgotten. Returns whether anything changed.
    @discardableResult
    func update(with albums: [AlbumID3], isWholeCatalog: Bool = false) -> Bool {
        let covers = albums.compactMap { album in album.coverArt.map { (album.id.raw, $0) } }
        let changed = lock.withLock { () -> Bool in
            var map = isWholeCatalog ? [:] : coverByAlbumId
            for (albumId, cover) in covers { map[albumId] = cover }
            if isWholeCatalog { hasCatalog = true }
            guard map != coverByAlbumId else { return false }
            coverByAlbumId = map
            return true
        }
        if changed { announce() }
        return changed
    }

    /// The cover of one album, from its own screen's data.
    @discardableResult
    func update(albumId: String, coverArt: String?) -> Bool {
        guard let coverArt else { return false }
        let changed = lock.withLock { coverByAlbumId.updateValue(coverArt, forKey: albumId) != coverArt }
        if changed { announce() }
        return changed
    }

    /// Gets the map in place before a list asks for its first covers: from the cached album list
    /// or — nothing cached yet — from the server, waiting `limit` for that at the most. What
    /// arrives later still applies.
    func prepare(limit: Duration = .seconds(2)) async {
        guard lock.withLock({ usesAlbumCover && !hasCatalog }) else { return }
        if let albums = await cachedCatalog() {
            update(with: albums, isWholeCatalog: true)
            return
        }
        let load: Task<Void, Never> = lock.withLock {
            if let loading { return loading }
            let task = Task { [weak self, fetchedCatalog] in
                let albums = await fetchedCatalog()
                guard let self, !Task.isCancelled else { return }
                if let albums { self.update(with: albums, isWholeCatalog: true) }
                self.lock.withLock { self.loading = nil }
            }
            loading = task
            return task
        }
        // Not a task group: that waits for all of its children, and the fetch is to carry on.
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let waiting = Task {
            await load.value
            end.finish()
        }
        let timeLimit = Task {
            try? await Task.sleep(for: limit)
            end.finish()
        }
        for await _ in ended {}
        timeLimit.cancel()
        waiting.cancel()
    }

    /// The album list from the server (or from the cache, if something filled it meanwhile).
    private static func fetchCatalog() async -> [AlbumID3]? {
        guard SubsonicClient.shared.isConfigured else { return nil }
        var albums: [AlbumID3]?
        for await event in LibraryLoader.load(.allAlbums(), shown: nil) {
            switch event {
            case .cached(let cached): albums = cached
            case .fresh(let fresh): albums = fresh
            case .upToDate, .failed: break
            }
        }
        return albums
    }

    /// Forgets everything: the library it came from is gone (another server).
    func reset() {
        let changed = lock.withLock { () -> Bool in
            loading?.cancel()
            loading = nil
            hasCatalog = false
            guard !coverByAlbumId.isEmpty else { return false }
            coverByAlbumId = [:]
            return true
        }
        if changed { announce() }
    }

    /// The preference was changed in Settings.
    func settingChanged() {
        let uses = ArtworkSettings.useAlbumCoverForSongs(defaults)
        let changed = lock.withLock { () -> Bool in
            guard uses != usesAlbumCover else { return false }
            usesAlbumCover = uses
            return true
        }
        guard changed else { return }
        if uses { Task { await prepare() } }
        announce()
    }

    /// Tells the screens, once for changes that come close together: a library sync caches
    /// hundreds of album lists one after another.
    private func announce() {
        let schedule = lock.withLock { () -> Bool in
            guard !announcementPending else { return false }
            announcementPending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: announceDelay)
            lock.withLock { announcementPending = false }
            ListArtworkChanges.shared.revision += 1
            NotificationCenter.default.post(name: Self.didChange, object: self)
            onChange()
        }
    }
}

/// What a view watches to redraw when `ListArtwork`'s answers change.
@MainActor
@Observable
final class ListArtworkChanges {
    static let shared = ListArtworkChanges()
    fileprivate(set) var revision = 0
}
