import SwiftUI

/// Track title/artist, the scrubber, transport buttons, and volume — the lower half of the
/// expanded Now Playing screen.
struct PlayerControls: View {
    @ObservedObject private var player = PlayerManager.shared
    var colors: [Color]
    /// Whether the title/artist marquees should be scrolling — false while this chrome is hidden,
    /// so an invisible copy does no per-frame work. See `NowPlayingMarquee`.
    var marqueesActive = true
    /// Bumped to restart the marquees from their start position. See `NowPlayingMarquee`.
    var marqueeRestartToken = 0

    var body: some View {
        GeometryReader {
            let size = $0.size
            let spacing = size.verticalSpacing
            VStack(spacing: 0) {
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
                .frame(height: size.height / 2.5, alignment: .top)
                controlsRow
                    .padding(.horizontal, NowPlayingLayout.cardPaddings)
                    .frame(height: size.height / 2.5, alignment: .bottom)
            }
        }
    }
}

private extension CGSize {
    var verticalSpacing: CGFloat { height * 0.04 }
}

private extension PlayerControls {
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

    /// The star (favorite) and AirPlay buttons flank the transport buttons in one row — star on
    /// the leading edge, AirPlay on the trailing edge, both the same size — same as Apple Music.
    var controlsRow: some View {
        HStack {
            starButton
            Spacer(minLength: 0)
            // Tighter than the `width * 0.14` this used when it had the row to itself — with
            // star and AirPlay now sharing the row too, that spacing overflowed the available
            // width and pushed AirPlay off the visible edge entirely.
            PlayerButtons(spacing: 12)
            Spacer(minLength: 0)
            airPlayButton
        }
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

    var starButton: some View {
        Button {
            player.toggleStarred()
        } label: {
            Image(systemName: player.isCurrentTrackStarred ? "star.fill" : "star")
                .font(.system(size: 22))
                .foregroundStyle(Color.transparentWhite)
                // Leading-aligned in its tap target rather than centered, so the glyph itself
                // sits on the row's edge — matching trackInfo's text — instead of `(44-20)/2`
                // points further in, with the extra tap area extending inward instead.
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(.rect)
        }
        .disabled(player.isRadio)
        .opacity(player.isRadio ? 0.3 : 1)
    }

    var airPlayButton: some View {
        AirPlayButton(size: 22)
            .foregroundStyle(Color.transparentWhite)
            .frame(width: 44, height: 44, alignment: .trailing)
            .contentShape(.rect)
    }
}
