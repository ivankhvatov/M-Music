import SwiftUI

/// Track title/artist and the scrubber — the upper half of the expanded Now Playing controls.
/// Hosted directly by `RegularChrome`, above `PlayerControls`' buttons.
struct PlayerTrackInfo: View {
    @ObservedObject private var player = PlayerManager.shared
    /// Vertical gap between the title block and the scrubber (`RegularChrome` derives it from the
    /// height available to the controls, so it scales with the screen).
    var spacing: CGFloat
    /// Whether the title/artist marquees should be scrolling — false while this chrome is hidden,
    /// so an invisible copy does no per-frame work. See `NowPlayingMarquee`.
    var marqueesActive = true
    /// Bumped to restart the marquees from their start position. See `NowPlayingMarquee`.
    var marqueeRestartToken = 0

    var body: some View {
        VStack(spacing: spacing) {
            trackInfo
            Group {
                if player.isRadio {
                    liveIndicator
                } else {
                    TimingIndicator(spacing: spacing)
                }
            }
                .padding(.top, spacing)
                // The slider itself adds `growth` more inset at rest (it shrinks off the
                // edges when idle, then grows to fill the row while being dragged) — back
                // that out here so its resting position lines up with `trackInfo`'s text
                // instead of sitting `growth` points further in. Verified pixel-for-pixel
                // against the title text with a temporary ruler overlay.
                .padding(.horizontal, NowPlayingLayout.cardPaddings - ElasticSliderConfig.playbackProgress.growth)
        }
    }
}

private extension PlayerTrackInfo {
    var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            NowPlayingMarquee(
                text: player.nowPlayingTitle,
                font: .preferred(.title3, weight: .semibold),
                isActive: marqueesActive,
                restartToken: marqueeRestartToken
            )
            .foregroundStyle(.white)
            NowPlayingMarquee(
                text: player.nowPlayingSubtitle,
                font: .preferred(.body),
                isActive: marqueesActive,
                restartToken: marqueeRestartToken
            )
            .foregroundStyle(Color.transparentWhite)
            if let audioInfoLine {
                Text(audioInfoLine)
                    .font(.caption)
                    .foregroundStyle(Color.transparentWhite.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NowPlayingLayout.cardPaddings)
    }

    /// "Stream · FLAC · 24-bit/96 kHz" or "Downloaded · AAC · 256 kbps" — `nil` while the "Show
    /// audio info" setting is off, nothing's playing, or the codec read
    /// (`PlayerManager.audioFormatInfo`) hasn't landed yet for the current track.
    var audioInfoLine: String? {
        guard AudioInfoDisplaySettings.isEnabled, player.currentTrack != nil,
              let source = player.playbackSource, let format = player.audioFormatInfo
        else { return nil }
        var parts = [source.displayName, format.codec]
        if let bitDepth = format.bitDepth, let sampleRateHz = format.sampleRateHz {
            parts.append("\(bitDepth)-bit/\(Self.formattedSampleRate(sampleRateHz))")
        } else if let bitrateKbps = format.bitrateKbps {
            parts.append("\(bitrateKbps) kbps")
        }
        return parts.joined(separator: " · ")
    }

    static func formattedSampleRate(_ hz: Double) -> String {
        let khz = (hz / 1000 * 10).rounded() / 10
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }

    /// Stands in for `TimingIndicator` while radio plays — same 60pt height so the layout below
    /// it doesn't shift, and inset like the slider's resting position so it lines up with `trackInfo`.
    var liveIndicator: some View {
        Text("LIVE")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.transparentWhite)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 60, alignment: .top)
            .padding(.top, 11)
            // The container already insets by `cardPaddings - growth`; add `growth` back so the
            // label lines up with `trackInfo`'s text.
            .padding(.horizontal, ElasticSliderConfig.playbackProgress.growth)
    }
}
