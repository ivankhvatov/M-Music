import SwiftUI

/// How much disk space `GaplessCacheService` is allowed to use in total before it starts evicting
/// the least-recently-played cached track. `Int`, not `Int64` — matches what `@AppStorage`'s
/// `RawRepresentable` overloads support; `Int` is 64-bit on iOS anyway, so these byte counts fit
/// without truncation.
enum GaplessCacheSizeLimit: Int, CaseIterable, Identifiable {
    case mb250 = 250_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000
    case gb2 = 2_000_000_000

    var id: Int { rawValue }

    var byteCount: Int64 { Int64(rawValue) }

    var displayName: LocalizedStringKey {
        switch self {
        case .mb250: return "250 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        }
    }
}

/// How long a cached track is kept without being played again before `GaplessCacheService` treats
/// it as stale and evicts it.
enum GaplessCacheRetention: Int, CaseIterable, Identifiable {
    case day1 = 1
    case day3 = 3
    case day7 = 7
    case day14 = 14

    var id: Int { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .day1: return "1 day"
        case .day3: return "3 days"
        case .day7: return "7 days"
        case .day14: return "14 days"
        }
    }
}

/// Keys and read-only accessors for the gapless-cache preferences configured in
/// `PlaybackSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage` for
/// two-way editing. This is for non-View code (`PlayerManager`, `GaplessCacheService`) that just
/// needs to read the current values.
enum GaplessCacheSettings {
    enum Keys {
        static let isEnabled = "gaplessCache.isEnabled"
        static let sizeLimit = "gaplessCache.sizeLimit"
        static let retention = "gaplessCache.retention"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    static var sizeLimit: GaplessCacheSizeLimit {
        GaplessCacheSizeLimit(rawValue: UserDefaults.standard.integer(forKey: Keys.sizeLimit)) ?? .mb500
    }

    static var retention: GaplessCacheRetention {
        GaplessCacheRetention(rawValue: UserDefaults.standard.integer(forKey: Keys.retention)) ?? .day3
    }
}
