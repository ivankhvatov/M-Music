import SwiftUI

/// The carousels `HomeView` can show. `allCases` is the default order.
enum HomeCarouselKind: String, CaseIterable, Identifiable {
    case randomAlbums
    case latestReleases
    case recentlyAdded
    case recentlyPlayed
    case favoriteArtistAlbums
    case topPlaylists

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .randomAlbums: "Random albums"
        case .latestReleases: "Latest releases"
        case .recentlyAdded: "Recently added"
        case .recentlyPlayed: "Recently played"
        case .favoriteArtistAlbums: "Albums from favorite artists"
        case .topPlaylists: "Top playlists"
        }
    }
}

/// Which Home carousels are shown and in what order, configured in `AppearanceSettingsView` and
/// read by `HomeView`; both bind to the same `UserDefaults` keys via `@AppStorage`. Order and
/// the disabled set are stored as comma-separated raw values, so a carousel added in a later
/// version simply shows up (enabled, at the end) for users who already saved a layout.
enum HomeContentSettings {
    enum Keys {
        static let order = "home.carouselOrder"
        static let disabled = "home.disabledCarousels"
    }

    /// Every carousel, in the saved order (unknown entries dropped, missing ones appended).
    static func order(from stored: String) -> [HomeCarouselKind] {
        var result: [HomeCarouselKind] = []
        for part in stored.split(separator: ",") {
            if let kind = HomeCarouselKind(rawValue: String(part)), !result.contains(kind) {
                result.append(kind)
            }
        }
        return result + HomeCarouselKind.allCases.filter { !result.contains($0) }
    }

    static func disabled(from stored: String) -> Set<HomeCarouselKind> {
        Set(stored.split(separator: ",").compactMap { HomeCarouselKind(rawValue: String($0)) })
    }

    static func encode(_ kinds: some Sequence<HomeCarouselKind>) -> String {
        kinds.map(\.rawValue).joined(separator: ",")
    }

    /// The carousels to show, in order.
    static func visible(order: String, disabled: String) -> [HomeCarouselKind] {
        let off = Self.disabled(from: disabled)
        return Self.order(from: order).filter { !off.contains($0) }
    }
}
