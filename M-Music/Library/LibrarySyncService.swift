import Foundation

/// Walks the whole library — every playlist's songs, every artist's albums, every album's songs,
/// plus the four top-level lists — and writes it all into `LibraryCacheDatabase`, so
/// stale-while-revalidate reads across every browsing screen have something to show immediately
/// even for items never actually visited this session. Runs paced (bounded concurrency, low
/// priority) entirely in the background; never awaited by its caller. Triggered once per
/// successful `SubsonicClient.connect()` — a newly started sync cancels whatever previous one was
/// still running (e.g. the user reconnects again before the first pass finished).
actor LibrarySyncService {
    static let shared = LibrarySyncService()

    private var currentTask: Task<Void, Never>?

    private init() {}

    func start(client: SubsonicClient) {
        currentTask?.cancel()
        currentTask = Task(priority: .background) {
            await Self.run(client: client)
        }
    }

    private static func run(client: SubsonicClient) async {
        let limiter = ConcurrencyLimiter(maxConcurrent: 3)

        if let playlists = try? await client.getPlaylists() {
            await LibraryCacheDatabase.shared.cacheAllPlaylists(playlists)
            await withTaskGroup(of: Void.self) { group in
                for playlist in playlists {
                    group.addTask {
                        guard await limiter.acquire() else { return }
                        defer { Task { await limiter.release() } }
                        guard let full = try? await client.getPlaylist(id: playlist.id.raw) else { return }
                        await LibraryCacheDatabase.shared.cachePlaylistSongs(full.entry ?? [], playlistId: playlist.id.raw)
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }

        if let artistsResult = try? await client.getArtists() {
            let artists = artistsResult.index.flatMap(\.artist)
            await LibraryCacheDatabase.shared.cacheAllArtists(artists)
            await withTaskGroup(of: Void.self) { group in
                for artist in artists {
                    group.addTask {
                        guard await limiter.acquire() else { return }
                        defer { Task { await limiter.release() } }
                        guard let full = try? await client.getArtist(id: artist.id.raw) else { return }
                        await LibraryCacheDatabase.shared.cacheArtistAlbums(full.album, artistId: artist.id.raw)
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }

        if let albums = try? await client.allAlbums() {
            await LibraryCacheDatabase.shared.cacheAllAlbums(albums)
            await withTaskGroup(of: Void.self) { group in
                for album in albums {
                    group.addTask {
                        guard await limiter.acquire() else { return }
                        defer { Task { await limiter.release() } }
                        guard let full = try? await client.getAlbum(id: album.id.raw) else { return }
                        await LibraryCacheDatabase.shared.cacheAlbumSongs(full, albumId: album.id.raw)
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }

        if let songs = try? await client.allSongs() {
            await LibraryCacheDatabase.shared.cacheAllSongs(songs)
        }
    }
}
