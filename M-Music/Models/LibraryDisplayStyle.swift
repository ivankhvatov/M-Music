import SwiftUI

/// Whether a library browse screen (Playlists, Albums) shows its items as a grid of cards or as
/// a scrollable list of rows — user-selectable per screen in `AppearanceSettingsView`, persisted
/// via `@AppStorage`.
enum LibraryDisplayStyle: LocalizedStringKey, CaseIterable {
    case grid = "Grid"
    case list = "List"

    /// Stable, non-localized identifier for persisting the selection — `rawValue` is a
    /// `LocalizedStringKey` and isn't suitable for storage.
    var storageKey: String {
        switch self {
        case .grid: return "grid"
        case .list: return "list"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .grid
    }
}
