import Foundation

/// Keys and read-only accessors for the on-device, post-download container-conversion
/// preferences configured in `DownloadsSettingsView`, which binds to the same `UserDefaults` keys
/// via `@AppStorage` for two-way editing. Read directly by `DownloadService` (non-View code), the
/// same way `DownloadTranscodingSettings.isEnabled` already is.
///
/// Both toggles only affect downloads finished after being turned on — see
/// `DownloadService.handleDownloadFinished`. Neither retroactively converts anything already on
/// disk.
enum DownloadConversionSettings {
    enum Keys {
        static let convertLosslessToALAC = "downloadConversion.convertLosslessToALAC"
        static let convertOpusToCAF = "downloadConversion.convertOpusToCAF"
    }

    /// When enabled, a newly finished lossless download whose sniffed container is FLAC, WAV, or
    /// AIFF (not APE/WV/DSF/DFF) is converted on-device to Apple Lossless (ALAC) in an `.m4a`
    /// container via `ExtAudioFile`, and the converted file replaces the original for playback.
    static var convertLosslessToALAC: Bool {
        UserDefaults.standard.bool(forKey: Keys.convertLosslessToALAC)
    }

    /// When enabled, a newly finished Opus download (native Opus, or transcoded to Opus per
    /// `DownloadTranscodingSettings`) is remuxed on-device into a `.caf` container via
    /// AudioToolbox's low-level `AudioFile` packet APIs (no decode/re-encode), and the remuxed
    /// file replaces the original for playback.
    static var convertOpusToCAF: Bool {
        UserDefaults.standard.bool(forKey: Keys.convertOpusToCAF)
    }
}
