import Foundation

/// Keys and read-only accessors for the artwork preferences configured in
/// `AppearanceSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage`.
enum ArtworkSettings {
    enum Keys {
        static let useAlbumCoverForSongs = "library.useAlbumCoverForSongs"
    }

    /// Whether a song's row in a list shows its album's cover rather than the song's own art — see
    /// `ListArtwork`. On unless it has been turned off (read through `object(forKey:)`, since an
    /// unset key would otherwise read as `false`).
    static func useAlbumCoverForSongs(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.useAlbumCoverForSongs) as? Bool ?? true
    }
}
