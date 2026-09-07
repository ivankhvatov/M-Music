import SwiftUI

/// Track title/artist, the scrubber, transport buttons, and volume — the lower half of the
/// expanded Now Playing screen.
struct PlayerControls: View {
    @ObservedObject private var player = PlayerManager.shared
    var colors: [Color]

    var body: some View {
        GeometryReader {
            let size = $0.size
            let spacing = size.verticalSpacing
            VStack(spacing: 0) {
                VStack(spacing: spacing) {
                    trackInfo
                    TimingIndicator(spacing: spacing)
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
            MarqueeText(text: player.currentTrack?.title ?? String(localized: "Not Playing"))
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            MarqueeText(text: player.currentTrack?.artist ?? "")
                .foregroundStyle(Color.transparentWhite)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NowPlayingLayout.cardPaddings)
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

    var starButton: some View {
        Button {
            player.toggleStarred()
        } label: {
            Image(systemName: player.isCurrentTrackStarred ? "star.fill" : "star")
                .font(.system(size: 20))
                .foregroundStyle(Color.transparentWhite)
                // Leading-aligned in its tap target rather than centered, so the glyph itself
                // sits on the row's edge — matching trackInfo's text — instead of `(44-20)/2`
                // points further in, with the extra tap area extending inward instead.
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(.rect)
        }
    }

    var airPlayButton: some View {
        AirPlayButton(size: 20)
            .foregroundStyle(Color.transparentWhite)
            .frame(width: 44, height: 44, alignment: .trailing)
            .contentShape(.rect)
    }
}
