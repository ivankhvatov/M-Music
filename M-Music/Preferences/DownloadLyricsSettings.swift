import Foundation

/// Key and read-only accessor for the "Download lyrics" preference configured in
/// `DownloadsSettingsView`, which binds to the same `UserDefaults` key via `@AppStorage` for
/// two-way editing. Read by `DownloadService` (non-View code) when a download finishes.
///
/// Only affects downloads finished after it's turned on — see `DownloadedLyrics`.
enum DownloadLyricsSettings {
    enum Keys {
        static let isEnabled = "downloadLyrics.isEnabled"
    }

    /// When enabled, a song's lyrics are saved along with the song when it finishes downloading,
    /// and read from there afterwards instead of from the server.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }
}
