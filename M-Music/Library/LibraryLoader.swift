import Foundation

/// Where one screen's data comes from and how it's cached — everything `LibraryLoader` needs to
/// run stale-while-revalidate for it without knowing anything about the type it's loading.
struct LibrarySource<Value: Equatable & Sendable>: Sendable {
    var readCache: @Sendable () async -> Value?
    var fetch: @Sendable () async throws -> Value
    var writeCache: @Sendable (Value) async -> Void
    /// An empty cached value counts as "nothing to show yet".
    var isEmpty: @Sendable (Value) -> Bool
    /// For whole-library lists derived from the server's scan: `getScanStatus` decides whether a
    /// re-download is needed at all (see `LibraryRevalidation`). `nil` = always revalidate.
    var scanList: LibraryRevalidation.List?

    init(
        scanList: LibraryRevalidation.List? = nil,
        isEmpty: @escaping @Sendable (Value) -> Bool,
        readCache: @escaping @Sendable () async -> Value? = { nil },
        writeCache: @escaping @Sendable (Value) async -> Void = { _ in },
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        self.scanList = scanList
        self.isEmpty = isEmpty
        self.readCache = readCache
        self.writeCache = writeCache
        self.fetch = fetch
    }
}

enum LibraryLoad<Value: Sendable>: Sendable {
    /// The last cached copy — show it right away; a revalidation may follow.
    case cached(Value)
    /// The server's answer differs from what's on screen — replace it.
    case fresh(Value)
    /// The server confirmed what's on screen (or in the cache) is current; nothing to do.
    case upToDate
    /// The load failed (offline, server error, …). Whatever is on screen should stay.
    case failed(Error)
}

/// The one stale-while-revalidate implementation behind every screen that shows server data:
/// cache read → "has anything changed?" gate → download → *compare* → cache write, all off the
/// main actor. A view only consumes the stream and assigns the value it's told to.
///
/// The work is tied to the consuming task: when the screen goes away (its `.task` is cancelled)
/// the stream's producer is cancelled too, so no further pages/requests are started for a screen
/// nobody is looking at. The one exception is persisting a download that already completed — that
/// runs detached so a finished (possibly expensive) fetch isn't thrown away, and so the
/// "synced as of scan X" token is only ever recorded after the data it describes is on disk.
enum LibraryLoader {
    static func load<Value: Equatable & Sendable>(
        _ source: LibrarySource<Value>,
        shown: Value?,
        force: Bool = false,
        revalidation: LibraryRevalidation = .shared,
        client: SubsonicClient = .shared
    ) -> AsyncStream<LibraryLoad<Value>> {
        let (stream, continuation) = AsyncStream<LibraryLoad<Value>>.makeStream()
        let producer = Task(priority: .userInitiated) {
            await run(source, shown: shown, force: force, revalidation: revalidation, client: client, continuation: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    private static func run<Value: Equatable & Sendable>(
        _ source: LibrarySource<Value>,
        shown: Value?,
        force: Bool,
        revalidation: LibraryRevalidation,
        client: SubsonicClient,
        continuation: AsyncStream<LibraryLoad<Value>>.Continuation
    ) async {
        var baseline = shown.flatMap { source.isEmpty($0) ? nil : $0 }
        if baseline == nil, let cached = await source.readCache(), !source.isEmpty(cached) {
            guard !Task.isCancelled else { return }
            baseline = cached
            continuation.yield(.cached(cached))
        }

        // The token is captured before the download, not after: a scan that finishes mid-fetch
        // must still trigger a refetch next time.
        var check: LibraryRevalidation.Check?
        if let list = source.scanList {
            let result = await revalidation.check(list, client: client)
            guard !Task.isCancelled else { return }
            if !force, baseline != nil, !result.needsRefetch {
                continuation.yield(.upToDate)
                return
            }
            check = result
        }

        do {
            let fetched = try await source.fetch()
            try Task.checkCancellation()
            // The "did the server data change?" comparison — on this background task, not the
            // main actor, where diffing a few thousand songs was a visible stall.
            let changed = fetched != baseline
            if changed {
                continuation.yield(.fresh(fetched))
            } else {
                continuation.yield(.upToDate)
            }
            let list = source.scanList
            let token = check?.token
            await Task.detached(priority: .utility) {
                if changed { await source.writeCache(fetched) }
                if let list { await revalidation.markSynced(list, token: token, client: client) }
            }.value
        } catch {
            guard !Self.isCancellation(error) else { return }
            continuation.yield(.failed(error))
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

// MARK: - Sources for each screen

extension LibrarySource where Value == [AlbumID3] {
    static func allAlbums(client: SubsonicClient = .shared) -> Self {
        Self(
            scanList: .albums,
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedAllAlbums() },
            writeCache: { await LibraryCacheDatabase.shared.cacheAllAlbums($0) },
            fetch: { try await client.allAlbums() }
        )
    }

    static func recentAlbums(client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedRecentAlbums() },
            writeCache: { await LibraryCacheDatabase.shared.cacheRecentAlbums($0) },
            fetch: { try await client.getAlbumList2(type: .recent, size: 30) }
        )
    }

    static func artistAlbums(artistId: String, client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedArtistAlbums(artistId: artistId) },
            writeCache: { await LibraryCacheDatabase.shared.cacheArtistAlbums($0, artistId: artistId) },
            fetch: { try await client.getArtist(id: artistId).album }
        )
    }
}

extension LibrarySource where Value == [ArtistID3] {
    static func allArtists(client: SubsonicClient = .shared) -> Self {
        Self(
            scanList: .artists,
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedAllArtists() },
            writeCache: { await LibraryCacheDatabase.shared.cacheAllArtists($0) },
            fetch: { try await client.getArtists().index.flatMap(\.artist) }
        )
    }
}

extension LibrarySource where Value == [Child] {
    static func allSongs(client: SubsonicClient = .shared) -> Self {
        Self(
            scanList: .songs,
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedAllSongs() },
            writeCache: { await LibraryCacheDatabase.shared.cacheAllSongs($0) },
            fetch: { try await client.allSongs() }
        )
    }

    static func playlistSongs(playlistId: String, client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedPlaylistSongs(playlistId: playlistId) },
            writeCache: { await LibraryCacheDatabase.shared.cachePlaylistSongs($0, playlistId: playlistId) },
            fetch: { try await client.getPlaylist(id: playlistId).entry ?? [] }
        )
    }
}

extension LibrarySource where Value == [PlaylistSummary] {
    /// No scan gate: playlists are edited without any library scan, and the list is one cheap request.
    static func allPlaylists(client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: \.isEmpty,
            readCache: { await LibraryCacheDatabase.shared.cachedAllPlaylists() },
            writeCache: { await LibraryCacheDatabase.shared.cacheAllPlaylists($0) },
            fetch: { try await client.getPlaylists() }
        )
    }
}

extension LibrarySource where Value == AlbumWithSongsID3 {
    /// Compared as the full `AlbumWithSongsID3`, not just its `.song` array, so a change to any
    /// cached field (not only the track list) still counts as changed.
    static func albumDetail(albumId: String, client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: { _ in false },
            readCache: { await LibraryCacheDatabase.shared.cachedAlbumSongs(albumId: albumId) },
            writeCache: { await LibraryCacheDatabase.shared.cacheAlbumSongs($0, albumId: albumId) },
            fetch: { try await client.getAlbum(id: albumId) }
        )
    }
}

extension LibrarySource where Value == [InternetRadioStation] {
    /// Not cached — just fetched and compared against what's on screen.
    static func radioStations(client: SubsonicClient = .shared) -> Self {
        Self(
            isEmpty: \.isEmpty,
            fetch: { try await client.getInternetRadioStations() }
        )
    }
}
