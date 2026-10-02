import Foundation
import UIKit

/// Keeps a permanent copy of the artwork for everything that has downloaded music, so it's still
/// there offline after iOS purges the regular image cache (see `ImageCache`).
///
/// For every downloaded song, all of these are saved — to the regular cache *and* the permanent
/// one, each with the thumbnail the matching list row requests as well as the full image:
///
/// - the **song's** artwork (song rows),
/// - its **album's** artwork (album rows and cards),
/// - its **artist's** picture (artist rows),
/// - and the artwork of every **playlist** that contains it (playlist rows and cards).
///
/// It's the same whether the song was downloaded on its own or as part of an album or playlist:
/// what matters is only that the song is downloaded. Nothing is saved for content that isn't — plain
/// browsing only ever fills the regular cache.
///
/// Rather than reacting to individual downloads, every trigger just asks for a *sync*: a pass over
/// all downloads that saves whatever artwork isn't saved yet. A pass that finds nothing missing is a
/// few file-existence checks, so it's cheap to run after any change that could add something —
/// a download finishing (or the app launching with earlier downloads), a playlist's songs or cover
/// being cached — and it also repairs anything that went missing, or was never saved by an older
/// version of the app.
actor DownloadedArtwork {
    static let shared = DownloadedArtwork()

    /// The artwork ids to save, by what they're the artwork of (each kind has its own row
    /// thumbnail size).
    struct Targets: Equatable, Sendable {
        var songs: Set<String> = []
        var albums: Set<String> = []
        var playlists: Set<String> = []
        var artists: Set<String> = []

        /// Every URL to save: each id's full image and its row thumbnail.
        func urls(scale: CGFloat, url: (_ id: String, _ size: Int?) -> URL?) -> [URL] {
            let kinds: [(ids: Set<String>, points: CGFloat)] = [
                (songs, ImageCache.RowArtwork.song),
                (albums, ImageCache.RowArtwork.album),
                (playlists, ImageCache.RowArtwork.playlist),
                (artists, ImageCache.RowArtwork.artist),
            ]
            var seen = Set<URL>()
            var result: [URL] = []
            for (ids, points) in kinds {
                let thumbnail = ImageCache.RowArtwork.pixels(points, scale: scale)
                for id in ids.sorted() {
                    for size in [nil, thumbnail] {
                        if let resolved = url(id, size), seen.insert(resolved).inserted {
                            result.append(resolved)
                        }
                    }
                }
            }
            return result
        }
    }

    /// What a download's album contributes: its own artwork id and its artist.
    struct AlbumInfo: Equatable, Sendable {
        let coverArt: String?
        let artistId: String?
    }

    // MARK: - Planning (pure)

    /// The albums the downloads belong to.
    static func albumIds(in records: [DownloadRecord]) -> Set<String> {
        Set(records.compactMap(\.albumId))
    }

    /// The artists the downloads belong to: the song's own artist, or — for a download made before
    /// that was recorded — its album's.
    static func artistIds(in records: [DownloadRecord], albums: [String: AlbumInfo]) -> Set<String> {
        Set(records.compactMap { artistId(of: $0, albums: albums) })
    }

    private static func artistId(of record: DownloadRecord, albums: [String: AlbumInfo]) -> String? {
        record.artistId ?? record.albumId.flatMap { albums[$0]?.artistId }
    }

    /// The artwork to save, from what's been resolved. `albums` and `artists` only hold the ones
    /// that could be resolved — an album or artist whose artwork id isn't known is skipped rather
    /// than guessed (a guessed id would be saved under a key nothing ever looks up). `artists`
    /// maps an artist id to its artwork id; `playlistArtwork` is the artwork id of each playlist
    /// that contains a downloaded song.
    static func targets(
        records: [DownloadRecord],
        albums: [String: AlbumInfo],
        artists: [String: String],
        playlistArtwork: Set<String>
    ) -> Targets {
        var targets = Targets()
        targets.playlists = playlistArtwork
        for record in records {
            // The same id `SongRow` and Now Playing request a song's artwork by.
            targets.songs.insert(record.coverArt ?? record.albumId ?? record.songId)
            if let albumId = record.albumId, let album = albums[albumId] {
                targets.albums.insert(album.coverArt ?? albumId)
            }
            if let artistId = artistId(of: record, albums: albums), let artwork = artists[artistId] {
                targets.artists.insert(artwork)
            }
        }
        return targets
    }

    // MARK: - Syncing

    private let client: SubsonicClient
    private let debounce: Duration
    private let maxConcurrentSaves = 3

    private var debounceTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var syncPending = false
    /// Lookups the server answered with an error (deleted on the server, ...), so each sync doesn't repeat them.
    private var failedLookups: Set<String> = []

    init(client: SubsonicClient = .shared, debounce: Duration = .seconds(2)) {
        self.client = client
        self.debounce = debounce
    }

    /// Asks for a sync. Calls close together — an album's worth of downloads finishing, a library
    /// sync caching dozens of playlists — are folded into one pass, run once things go quiet.
    func requestSync() {
        syncPending = true
        debounceTask?.cancel()
        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.startPass()
        }
    }

    private func startPass() {
        debounceTask = nil
        guard syncPending, passTask == nil else { return }
        passTask = Task(priority: .utility) {
            await self.runPasses()
        }
    }

    private func runPasses() async {
        // A request that arrives mid-pass sets `syncPending` again, so it's picked up right here.
        while syncPending {
            syncPending = false
            await syncOnce()
        }
        passTask = nil
    }

    /// Saves whatever artwork the downloads need that isn't saved yet. Runs a single pass now.
    func syncOnce() async {
        let records = await DownloadDatabase.shared.allRecords()
        guard !records.isEmpty, client.isConfigured else { return }

        let albums = await resolveAlbums(Self.albumIds(in: records))
        let artists = await resolveArtists(Self.artistIds(in: records, albums: albums))
        let playlistArtwork = await resolvePlaylistArtwork(downloadedSongIds: Set(records.map(\.songId)))
        let targets = Self.targets(records: records, albums: albums, artists: artists, playlistArtwork: playlistArtwork)

        let scale = await MainActor.run { UIScreen.main.scale }
        let client = client
        let urls = targets.urls(scale: scale) { id, size in client.cachedCoverArtURL(forId: id, size: size) }
        await save(urls)
    }

    /// Saves `urls` a few at a time.
    private func save(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            var running = 0
            while !Task.isCancelled, let url = iterator.next() {
                if running >= maxConcurrentSaves {
                    await group.next()
                    running -= 1
                }
                group.addTask { _ = await ImageCache.shared.savePermanently(url) }
                running += 1
            }
        }
    }

    // MARK: - Resolving ids

    /// Each album's artwork id and artist — from the library cache (opening an album, or the
    /// library sync, already put it there in the common case), falling back to a live lookup only
    /// while online.
    private func resolveAlbums(_ ids: Set<String>) async -> [String: AlbumInfo] {
        var result: [String: AlbumInfo] = [:]
        for albumId in ids {
            if let cached = await LibraryCacheDatabase.shared.cachedAlbumSongs(albumId: albumId) {
                result[albumId] = AlbumInfo(coverArt: cached.coverArt, artistId: cached.artistId?.raw)
            } else if let live = await lookup("album:\(albumId)", { try await self.client.getAlbum(id: albumId) }) {
                result[albumId] = AlbumInfo(coverArt: live.coverArt, artistId: live.artistId?.raw)
            }
        }
        return result
    }

    /// Each artist's artwork id — same approach as `resolveAlbums`.
    private func resolveArtists(_ ids: Set<String>) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let cached = await LibraryCacheDatabase.shared.cachedAllArtists() ?? []
        let cachedById = Dictionary(cached.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for artistId in ids {
            if let artist = cachedById[artistId] {
                result[artistId] = artist.coverArt ?? artistId
            } else if let live = await lookup("artist:\(artistId)", { try await self.client.getArtist(id: artistId) }) {
                result[artistId] = live.coverArt ?? artistId
            }
        }
        return result
    }

    /// The artwork id of every cached playlist that contains a downloaded song.
    private func resolvePlaylistArtwork(downloadedSongIds: Set<String>) async -> Set<String> {
        let playlistIds = await LibraryCacheDatabase.shared.playlistIds(containingAnyOf: downloadedSongIds)
        guard !playlistIds.isEmpty else { return [] }
        let playlists = await LibraryCacheDatabase.shared.cachedAllPlaylists() ?? []
        return Set(playlists.filter { playlistIds.contains($0.id.raw) }.map { $0.coverArt ?? $0.id.raw })
    }

    /// A live server lookup, only while online. Not repeated once the server has answered that it
    /// doesn't have the thing; any other failure (a dropped connection, ...) is retried next sync.
    private func lookup<T>(_ key: String, _ fetch: () async throws -> T) async -> T? {
        guard NetworkMonitor.shared.hasNetwork, !failedLookups.contains(key) else { return nil }
        do {
            return try await fetch()
        } catch {
            if case SubsonicError.server = error { failedLookups.insert(key) }
            return nil
        }
    }
}
