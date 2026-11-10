import SwiftUI

/// The carousels `HomeView` can show. `allCases` is the default order.
enum HomeCarouselKind: String, CaseIterable, Identifiable {
    case randomAlbums
    case latestReleases
    case recentlyAdded
    case recentlyPlayed
    case favoriteArtistAlbums
    case topPlaylists
    /// Not one carousel but a configurable number of them, each with a random genre's albums.
    case randomGenres

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .randomAlbums: "Random albums"
        case .latestReleases: "Latest releases"
        case .recentlyAdded: "Recently added"
        case .recentlyPlayed: "Recently played"
        case .favoriteArtistAlbums: "Albums from favorite artists"
        case .topPlaylists: "Top playlists"
        case .randomGenres: "Random genres"
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
        static let randomGenreCount = "home.randomGenreCount"
    }

    static let randomGenreRange = 0...10

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

    /// The carousels to show, in order. Random genres has no on/off switch: it's shown while its
    /// count is above zero.
    static func visible(order: String, disabled: String, randomGenreCount: Int = 0) -> [HomeCarouselKind] {
        let off = Self.disabled(from: disabled)
        return Self.order(from: order).filter {
            $0 == .randomGenres ? randomGenreCount > 0 : !off.contains($0)
        }
    }
}

/// The genres the "Random genres" carousels were last picked with, kept between launches so they
/// only change once `lifetime` has passed. The date is when the current picks were made — adding
/// a carousel or a restart doesn't extend it.
enum HomeGenrePicks {
    static let lifetime: TimeInterval = 24 * 60 * 60

    private static let namesKey = "home.genrePicks.names"
    private static let dateKey = "home.genrePicks.date"

    /// The genre names to keep showing; empty once they're older than `lifetime` (or never picked).
    static func pinned(now: Date = Date(), defaults: UserDefaults = .standard) -> [String] {
        guard let date = defaults.object(forKey: dateKey) as? Date,
              now.timeIntervalSince(date) < lifetime,
              let names = defaults.stringArray(forKey: namesKey) else { return [] }
        return names
    }

    /// Records what is now being shown. While the previous picks are still fresh the date stays,
    /// so the 24 hours count from when they were first picked.
    static func remember(_ names: [String], now: Date = Date(), defaults: UserDefaults = .standard) {
        guard !names.isEmpty else { return }
        if pinned(now: now, defaults: defaults).isEmpty {
            defaults.set(now, forKey: dateKey)
        }
        defaults.set(names, forKey: namesKey)
    }
}
