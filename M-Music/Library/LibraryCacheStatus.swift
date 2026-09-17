import Foundation

/// A synchronous, `@MainActor` mirror of `LibraryCacheDatabase`'s `playlistSongs` category —
/// exists for the same reason `LocalDownloadIndex`/`GaplessCacheStatus` exist alongside their own
/// actor-backed databases: `PlaylistCardView`/`PlaylistsListView`'s row need an instant,
/// non-`await`-able answer to "does this playlist have any downloaded song" (cross-referencing
/// against `DownloadStore.shared.isDownloaded(_:)`), and an `actor` can't offer that.
@MainActor
final class LibraryCacheStatus: ObservableObject {
    static let shared = LibraryCacheStatus()

    @Published private(set) var songIdsByPlaylistId: [String: [String]] = [:]

    private init() {}

    func songIds(forPlaylist playlistId: String) -> [String]? {
        songIdsByPlaylistId[playlistId]
    }

    func setSongIds(_ songIds: [String], forPlaylist playlistId: String) {
        songIdsByPlaylistId[playlistId] = songIds
    }

    /// Loads every previously-cached playlist's song-id list — called once, lazily, from
    /// `PlaylistsListView`'s first appearance, so playlists cached in an earlier session gray out
    /// correctly before any playlist is opened this session.
    private var didPreload = false
    func preload() async {
        guard !didPreload else { return }
        didPreload = true
        let byPlaylistId = await LibraryCacheDatabase.shared.allPlaylistSongIds()
        songIdsByPlaylistId.merge(byPlaylistId) { _, new in new }
    }
}
