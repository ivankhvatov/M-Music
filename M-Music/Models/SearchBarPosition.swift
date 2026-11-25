import SwiftUI

/// Where the Search tab's search field is — user-selectable in `AppearanceSettingsView`, persisted
/// via `@AppStorage`.
enum SearchBarPosition: LocalizedStringKey, CaseIterable {
    /// Under the title, in a normal tab.
    case top = "Top"
    /// The system's search field, in the tab bar (the Search tab has the search role). Screens
    /// pushed from there must not switch the window's colour scheme, or they lose their push
    /// animation — see `View.darkAppearance()`.
    case bottom = "Bottom"

    static let storageKey = "search.barPosition"

    /// Stable, non-localized identifier for persisting the selection — `rawValue` is a
    /// `LocalizedStringKey` and isn't suitable for storage.
    var stored: String {
        switch self {
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }

    init(stored: String) {
        self = Self.allCases.first { $0.stored == stored } ?? .top
    }
}
