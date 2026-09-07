import Foundation
import SwiftUI

enum ReplayGainMode: String, CaseIterable, Identifiable {
    case track, album

    var id: String { rawValue }

    /// `LocalizedStringKey`, not `String` — `Text(String)` resolves to the non-localizing
    /// "verbatim" initializer and would silently skip the string catalog entirely.
    var displayName: LocalizedStringKey {
        switch self {
        case .track: return "Track"
        case .album: return "Album"
        }
    }
}

/// Keys and read-only accessors for the ReplayGain preferences configured in
/// `PlaybackSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage` for
/// two-way editing. This is for non-View code (`PlayerManager`) that just needs to read the
/// current values and compute the actual volume adjustment to apply during playback.
enum ReplayGainSettings {
    enum Keys {
        static let isEnabled = "replayGain.isEnabled"
        static let mode = "replayGain.mode"
        static let preventClipping = "replayGain.preventClipping"
        static let preAmp = "replayGain.preAmp"
        static let defaultGain = "replayGain.defaultGain"
    }

    /// Kept in sync with `PlaybackSettingsView`'s `@AppStorage` default arguments by hand, since
    /// `UserDefaults.bool(forKey:)`/friends return their own zero-value (not these) for a key
    /// that was never written — see each accessor below.
    static let defaultPreventClipping = true
    static let defaultPreAmp: Double = 0
    static let defaultDefaultGain: Double = 0

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    static var mode: ReplayGainMode {
        UserDefaults.standard.string(forKey: Keys.mode).flatMap(ReplayGainMode.init(rawValue:)) ?? .track
    }

    static var preventClipping: Bool {
        UserDefaults.standard.object(forKey: Keys.preventClipping) as? Bool ?? defaultPreventClipping
    }

    static var preAmp: Double {
        UserDefaults.standard.object(forKey: Keys.preAmp) as? Double ?? defaultPreAmp
    }

    static var defaultGain: Double {
        UserDefaults.standard.object(forKey: Keys.defaultGain) as? Double ?? defaultDefaultGain
    }

    /// The linear volume multiplier to apply for `track`'s ReplayGain metadata, per the current
    /// settings — `1.0` means "no change, play at normal volume". Mirrors the formula Navidrome's
    /// own web player uses (`ui/src/utils/calculateReplayGain.js`):
    /// `10^((gain + preAmp) / 20)`, optionally capped at `1/peak` so the result never clips.
    ///
    /// When the track has no gain value for the selected mode (and the server reported no
    /// `fallbackGain` either), `defaultGain` stands in for it — this is what makes untagged
    /// tracks in an otherwise ReplayGain-normalized library not play jarringly louder/quieter.
    static func linearGain(for track: Child) -> Double {
        guard isEnabled else { return 1 }

        let gainDB: Double
        let peak: Double?
        switch mode {
        case .track:
            gainDB = track.replayGain?.trackGain ?? track.replayGain?.fallbackGain ?? defaultGain
            peak = track.replayGain?.trackPeak
        case .album:
            gainDB = track.replayGain?.albumGain ?? track.replayGain?.fallbackGain ?? defaultGain
            peak = track.replayGain?.albumPeak
        }

        var linear = pow(10, (gainDB + preAmp) / 20)
        if preventClipping, let peak, peak > 0 {
            linear = min(linear, 1 / peak)
        }
        return max(0, linear)
    }
}
