import SwiftUI

enum TranscodingFormat: String, CaseIterable, Identifiable {
    case mp3, aac, opus

    var id: String { rawValue }

    /// `LocalizedStringKey`, not `String` — `Text(String)` resolves to the non-localizing
    /// "verbatim" initializer and would silently skip the string catalog entirely.
    var displayName: LocalizedStringKey {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .opus: return "Opus"
        }
    }
}

enum TranscodingBitrate: Int, CaseIterable, Identifiable {
    case k64 = 64
    case k96 = 96
    case k128 = 128
    case k192 = 192
    case k256 = 256
    case k320 = 320

    var id: Int { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .k64: return "64 kbps"
        case .k96: return "96 kbps"
        case .k128: return "128 kbps"
        case .k192: return "192 kbps"
        case .k256: return "256 kbps"
        case .k320: return "320 kbps"
        }
    }
}

/// Which files transcoding applies to.
enum TranscodeFileScope: String, CaseIterable, Identifiable {
    case all
    /// Only transcode files whose codec is lossless (FLAC, ALAC, ...) — already-lossy files
    /// (MP3, AAC, ...) are streamed as-is, since re-encoding them would only lose more quality
    /// without the bandwidth win that matters for lossless sources.
    case losslessOnly

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .losslessOnly: return "Lossless only"
        }
    }
}

/// Which network types transcoding applies over.
enum TranscodeNetwork: String, CaseIterable, Identifiable {
    case wifi, cellular, both

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .both: return "Wi-Fi + Cellular"
        }
    }
}

/// Keys and read-only accessors for the transcoding preferences configured in
/// `PlaybackSettingsView`, which binds to the same `UserDefaults` keys via `@AppStorage` for
/// two-way editing. This is for non-View code (`PlayerManager`) that just needs to read the
/// current values when deciding how to build a stream URL.
enum TranscodingSettings {
    enum Keys {
        static let isEnabled = "transcoding.isEnabled"
        static let format = "transcoding.format"
        static let bitrate = "transcoding.bitrate"
        static let fileScope = "transcoding.fileScope"
        static let network = "transcoding.network"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    static var format: TranscodingFormat {
        UserDefaults.standard.string(forKey: Keys.format).flatMap(TranscodingFormat.init(rawValue:)) ?? .mp3
    }

    static var bitrate: TranscodingBitrate {
        TranscodingBitrate(rawValue: UserDefaults.standard.integer(forKey: Keys.bitrate)) ?? .k192
    }

    static var fileScope: TranscodeFileScope {
        UserDefaults.standard.string(forKey: Keys.fileScope).flatMap(TranscodeFileScope.init(rawValue:)) ?? .all
    }

    static var network: TranscodeNetwork {
        UserDefaults.standard.string(forKey: Keys.network).flatMap(TranscodeNetwork.init(rawValue:)) ?? .both
    }
}
