import Foundation

/// Key and read-only accessor for the "Translate genres" preference configured in
/// `AppearanceSettingsView`, which binds to the same `UserDefaults` key via `@AppStorage`.
enum GenreTranslationSettings {
    enum Keys {
        static let isEnabled = "genres.translate"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }
}
