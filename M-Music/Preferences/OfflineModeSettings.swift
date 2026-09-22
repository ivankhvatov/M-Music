import Foundation

/// Keys and read-only accessors for the "Offline mode" preferences configured in
/// `AppearanceSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage` for
/// two-way editing. All three default to `true` (today's "show, but dimmed" behavior) — since
/// `UserDefaults.bool(forKey:)` defaults to `false` for an unset key, these read via
/// `object(forKey:) as? Bool ?? true` instead, matching
/// `DownloadTranscodingSettings.prioritizeDownloads`'s existing default-`true` pattern.
enum OfflineModeSettings {
    enum Keys {
        static let showUnavailableInLists = "offlineMode.showUnavailableInLists"
        static let showUnavailableInAlbums = "offlineMode.showUnavailableInAlbums"
        static let showUnavailableInPlaylists = "offlineMode.showUnavailableInPlaylists"
    }

    /// When `false`, offline: non-downloaded songs are hidden (not just dimmed) in
    /// `SongsListView`; playlists not fully downloaded are hidden in `PlaylistsListView`;
    /// artists with no fully-downloaded album are hidden in `ArtistsListView`; albums not fully
    /// downloaded are hidden in `AlbumsListView`/`ArtistAlbumsView`.
    static var showUnavailableInLists: Bool {
        UserDefaults.standard.object(forKey: Keys.showUnavailableInLists) as? Bool ?? true
    }

    /// When `false`, offline: `AlbumView`'s non-downloaded tracks are hidden, not just dimmed.
    static var showUnavailableInAlbums: Bool {
        UserDefaults.standard.object(forKey: Keys.showUnavailableInAlbums) as? Bool ?? true
    }

    /// When `false`, offline: `PlaylistView`'s non-downloaded tracks are hidden, not just dimmed.
    static var showUnavailableInPlaylists: Bool {
        UserDefaults.standard.object(forKey: Keys.showUnavailableInPlaylists) as? Bool ?? true
    }
}
