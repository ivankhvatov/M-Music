import Foundation

/// Keys and read-only accessors for the scrobbling preferences configured in
/// `PlaybackSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage` for
/// two-way editing. Read by `PlayerManager` and `ScrobbleService` (non-View code). Defaults must
/// match the `@AppStorage` defaults in that view — an unset key is treated as "on" / 50%.
enum ScrobbleSettings {
    enum Keys {
        static let isEnabled = "scrobbling.isEnabled"
        static let threshold = "scrobbling.threshold"
        static let fromPlaylists = "scrobbling.fromPlaylists"
    }

    static let defaultThreshold = 0.5

    /// Whether plays are reported to the server at all. `bool(forKey:)` would read an unset key as
    /// `false`, so this is the default-on pattern used by `OfflineModeSettings`.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.isEnabled) as? Bool ?? true
    }

    /// Whether plays from a queue that was started from a playlist are scrobbled too. Default on,
    /// same pattern as `isEnabled`.
    static var scrobbleFromPlaylists: Bool {
        UserDefaults.standard.object(forKey: Keys.fromPlaylists) as? Bool ?? true
    }

    /// The fraction of a song (0...1) that must have played before it's scrobbled: 0 scrobbles as
    /// soon as it starts, 1 only once it's been played all the way through.
    static var threshold: Double {
        let value = UserDefaults.standard.object(forKey: Keys.threshold) as? Double ?? defaultThreshold
        return min(max(value, 0), 1)
    }
}
