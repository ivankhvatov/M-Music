import SwiftUI

/// Title and artist of the expanded Now Playing screen. Normally sits full-width above the
/// scrubber; with the queue showing it's offset up beside the (shrunken) artwork instead, in a
/// smaller font. Both are the same view with different numbers, so toggling animates as a move —
/// `RegularChrome` reserves its layout space accordingly (see `RegularChrome.lowerRegion`).
struct PlayerTrackTitle: View {
    @ObservedObject private var player = PlayerManager.shared
    var isCompact = false
    /// Width of the screen this sits on, to work out how much room the shrunken text can take.
    var width: CGFloat
    /// Whether the title/artist marquees should be scrolling — false while this chrome is hidden,
    /// so an invisible copy does no per-frame work. See `NowPlayingMarquee`.
    var marqueesActive = true
    /// Bumped to restart the marquees from their start position. See `NowPlayingMarquee`.
    var marqueeRestartToken = 0

    /// Height of the audio-info line (caption), which collapses to nothing with the queue showing.
    @ScaledMetric(relativeTo: .caption) private var audioInfoHeight: CGFloat = 15

    /// The text is laid out identically in both modes and merely scaled down with the queue
    /// showing, so the toggle is nothing but numeric changes (scale, padding, offset) that all ride
    /// the one animation. Swapping fonts instead re-lays the text out at once, which made it jump
    /// ahead of the rest of the move.
    private static let queueScale: CGFloat = 0.86

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.top, 4)
            if let audioInfoLine {
                Text(audioInfoLine)
                    .font(.caption)
                    .foregroundStyle(Color.transparentWhite.opacity(0.7))
                    .frame(height: isCompact ? 0 : audioInfoHeight, alignment: .top)
                    .clipped()
                    .opacity(isCompact ? 0 : 1)
                    .padding(.top, isCompact ? 0 : 4)
            }
        }
        .scaleEffect(isCompact ? Self.queueScale : 1, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, NowPlayingLayout.cardPaddings + (isCompact ? RegularNowPlayingLayout.queueTitleInset : 0))
        // Scaling shrinks the text toward its leading edge, so the trailing padding gives back what
        // that leaves unused, and the text still reaches the same right edge.
        .padding(.trailing, NowPlayingLayout.cardPaddings - (isCompact ? unusedWidthWhenScaled : 0))
        // With the queue showing, the block is exactly as tall as the artwork it sits beside, its
        // text centered in that height, and shifted up onto the artwork's row.
        .frame(minHeight: isCompact ? RegularNowPlayingLayout.Const.queueArtworkSide : 0)
        .offset(y: isCompact ? -RegularNowPlayingLayout.queueTitleRise : 0)
        // Fades out over the first part of the move and back in over the rest, so the text
        // visibly travels between its two places instead of popping between them. Run by the
        // toggle itself (it only fires on a change, never on first appearance) for exactly as
        // long as the move.
        .keyframeAnimator(initialValue: 1.0, trigger: isCompact) { content, opacity in
            content.opacity(opacity)
        } keyframes: { _ in
            let duration = Animation.playerQueueAnimationDuration
            CubicKeyframe(0, duration: duration * 0.4)
            CubicKeyframe(1, duration: duration * 0.6)
        }
    }

    /// How much of the text column's width goes unused once it's scaled down to `queueScale`.
    private var unusedWidthWhenScaled: CGFloat {
        let column = width - NowPlayingLayout.cardPaddings * 2 - RegularNowPlayingLayout.queueTitleInset
        return column * (1 / Self.queueScale - 1)
    }

    /// "Stream · FLAC · 24-bit/96 kHz" or "Downloaded · AAC · 256 kbps" — `nil` while the "Show
    /// audio info" setting is off, nothing's playing, or the codec read
    /// (`PlayerManager.audioFormatInfo`) hasn't landed yet for the current track.
    private var audioInfoLine: String? {
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

    private static func formattedSampleRate(_ hz: Double) -> String {
        let khz = (hz / 1000 * 10).rounded() / 10
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}

/// The scrubber (or the "LIVE" marker while radio plays).
struct PlayerProgress: View {
    @ObservedObject private var player = PlayerManager.shared
    var spacing: CGFloat

    var body: some View {
        Group {
            if player.isRadio {
                liveIndicator
            } else {
                TimingIndicator(spacing: spacing)
            }
        }
        // The slider itself adds `growth` more inset at rest (it shrinks off the
        // edges when idle, then grows to fill the row while being dragged) — back
        // that out here so its resting position lines up with the title's text
        // instead of sitting `growth` points further in. Verified pixel-for-pixel
        // against the title text with a temporary ruler overlay.
        .padding(.horizontal, NowPlayingLayout.cardPaddings - ElasticSliderConfig.playbackProgress.growth)
    }

    /// Stands in for `TimingIndicator` while radio plays — same 60pt height so the layout below
    /// it doesn't shift, and inset like the slider's resting position so it lines up with the title.
    private var liveIndicator: some View {
        Text("LIVE")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.transparentWhite)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 60, alignment: .top)
            .padding(.top, 11)
            // The container already insets by `cardPaddings - growth`; add `growth` back so the
            // label lines up with the title's text.
            .padding(.horizontal, ElasticSliderConfig.playbackProgress.growth)
    }
}
