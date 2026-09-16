import Foundation

/// Keys and read-only accessor for the "Show audio info" preference configured in
/// `AppearanceSettingsView`, which binds to the same `UserDefaults` key via `@AppStorage` for
/// two-way editing. This is for non-View code (`PlayerView`) that just needs to read the current
/// value.
enum AudioInfoDisplaySettings {
    enum Keys {
        static let isEnabled = "player.showAudioInfo"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }
}
