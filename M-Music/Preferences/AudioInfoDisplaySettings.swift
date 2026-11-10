import Foundation

/// Keys and read-only accessor for the "Show audio info" preference configured in
/// `AppearanceSettingsView`, which binds to the same `UserDefaults` key via `@AppStorage` for
/// two-way editing. This is for non-View code (`PlayerView`) that just needs to read the current
/// value, and builds the line the players show.
enum AudioInfoDisplaySettings {
    enum Keys {
        static let isEnabled = "player.showAudioInfo"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.isEnabled)
    }

    /// "Stream · FLAC · 24-bit/96 kHz" or "Downloaded · AAC · 256 kbps" for the current track.
    /// While its codec read is still in flight (briefly, on every track change) it's a "Loading…"
    /// placeholder rather than nothing, so the line keeps its place and the layout doesn't shift.
    /// `nil` while the setting is off, nothing's playing, radio plays, or the read failed.
    @MainActor
    static func line(for player: PlayerManager) -> String? {
        guard isEnabled, player.currentTrack != nil, !player.isRadio else { return nil }
        guard let source = player.playbackSource, let format = player.audioFormatInfo else {
            return player.isLoadingAudioFormat ? String(localized: "Loading…") : nil
        }
        var parts = [source.displayName, format.codec]
        if let bitDepth = format.bitDepth, let sampleRateHz = format.sampleRateHz {
            parts.append("\(bitDepth)-bit/\(formattedSampleRate(sampleRateHz))")
        } else if let bitrateKbps = format.bitrateKbps {
            parts.append("\(bitrateKbps) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private static func formattedSampleRate(_ hz: Double) -> String {
        let khz = (hz / 1000 * 10).rounded() / 10
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}
