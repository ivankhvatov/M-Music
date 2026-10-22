import SwiftUI

/// The collapsed mini player row's non-artwork content — marquee title/artist and play/pause +
/// forward buttons — with a leading placeholder reserving the artwork's spot. Kept separate from
/// the artwork itself (see `CompactArtwork`) so `ExpandableNowPlaying` can swap the two
/// independently: nesting a `matchedGeometryEffect` view inside a `.transition()`-ed parent breaks
/// that parent's own removal animation (it cuts short instead of animating), which is what made
/// this content vanish instantly on expand instead of fading out with the rest of the grow.
struct CompactChrome: View {
    @ObservedObject private var player = PlayerManager.shared
    /// Whether the title/artist marquees should be scrolling — false while this chrome is hidden,
    /// so an invisible copy does no per-frame work. See `NowPlayingMarquee`.
    var marqueesActive = true
    /// Changing this restarts both marquees from their start position. See `NowPlayingMarquee`.
    var marqueeRestartToken = 0
    @State private var forwardAnimationTrigger: PlayerButtonTrigger = .one(bouncing: false)
    @State private var viewWidth: CGFloat = .zero

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 30, height: 30)
            VStack(spacing: 0) {
                NowPlayingMarquee(
                    text: player.nowPlayingTitle,
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    fade: 8,
                    isActive: marqueesActive,
                    restartToken: marqueeRestartToken
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                NowPlayingMarquee(
                    text: player.nowPlayingSubtitle,
                    font: .systemFont(ofSize: 12, weight: .regular),
                    fade: 8,
                    isActive: marqueesActive,
                    restartToken: marqueeRestartToken
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .geometryGroup()
            .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                PlayerButton(
                    label: { playPauseLabel },
                    onEnded: { player.togglePlayPause() }
                )
                if !inlinedBottomAccessory, !player.isRadio {
                    PlayerButton(
                        label: {
                            PlayerButtonLabel(type: .forward, size: 26, animationTrigger: forwardAnimationTrigger)
                        },
                        onEnded: {
                            player.next()
                            DispatchQueue.main.async {
                                forwardAnimationTrigger.toggle(bouncing: true)
                            }
                        }
                    )
                }
            }
            .playerButtonStyle(.miniPlayer)
        }
        .padding(.leading, 16)
        .padding(.trailing, 13)
        .frame(height: NowPlayingLayout.compactHeight)
        .contentShape(.rect)
        .onTapGesture {
            // Nothing loaded means nothing to expand into (and the full-screen player isn't even
            // mounted yet — see `MainView`).
            guard player.currentTrack != nil || player.isRadio else { return }
            // The expanded chrome sits mounted at opacity 0 while collapsed, and an update SwiftUI
            // dropped for it in the meantime (see `PlayerManager`'s foreground republish) would
            // otherwise show — e.g. a play/pause button that doesn't match the player — and only
            // get corrected, visibly, inside the expand animation. Republish first, with
            // animations off, so it's already right by the time it fades in — but only when
            // something has changed since the last expand (see `republishForExpandIfNeeded`).
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { player.republishForExpandIfNeeded() }
            PlayerPresentation.shared.expand()
        }
        .onGeometryChange(
            for: CGFloat.self,
            of: { $0.size.width.roundedToPoint },
            action: {
                // See the matching guard in MainView — `.onGeometryChange` can re-fire with
                // sub-point floating-point jitter frame to frame even when nothing visually
                // moved. Rounding before comparing is what actually makes the guard dedupe;
                // comparing raw values never did.
                guard viewWidth != $0 else { return }
                viewWidth = $0
            }
        )
    }

    private var inlinedBottomAccessory: Bool {
        let padding = UIScreen.size.width - viewWidth
        return padding > 60
    }

    @ViewBuilder
    private var playPauseLabel: some View {
        if player.isBuffering {
            ProgressView()
        } else {
            PlayerButtonLabel(type: player.isPlaying ? .pause : .play, size: 16)
        }
    }
}

/// The collapsed mini player row's artwork alone, positioned via a leading placeholder + trailing
/// spacer that mirrors `CompactChrome`'s own leading placeholder exactly, so the two align
/// pixel-for-pixel without duplicating layout constants by hand. See `CompactChrome`'s doc comment
/// for why the two are kept apart.
struct CompactArtwork: View {
    @ObservedObject private var player = PlayerManager.shared
    /// Only the copy of this view living inside `ExpandableNowPlaying` (paired there with
    /// `RegularNowPlaying`'s artwork) needs this — pass `nil` for a standalone copy like the one
    /// composed into the tab-bar-docked `CompactNowPlaying` in `MainView`. A
    /// `matchedGeometryEffect` with no destination is a permanently-mounted "source" for its id,
    /// and `.tabViewBottomAccessory` content can get transiently re-hosted by the system across
    /// tab switches — briefly producing two live sources for the same id and crashing SwiftUI
    /// ("Multiple inserted views ... isSource: true"). Keeping the effect scoped to just the
    /// paired instance avoids that.
    var animationNamespace: Namespace.ID?

    var body: some View {
        HStack(spacing: 0) {
            artwork
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .frame(height: NowPlayingLayout.compactHeight)
    }

    @ViewBuilder
    private var artwork: some View {
        if let animationNamespace {
            TrackArtworkView(url: player.artworkURL, cornerRadius: 5)
                .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
                .frame(width: 30, height: 30)
        } else {
            TrackArtworkView(url: player.artworkURL, cornerRadius: 5)
                .frame(width: 30, height: 30)
        }
    }
}

/// The collapsed mini player row — artwork, marquee title/artist, and play/pause + forward
/// buttons — docked into the tab bar. Tapping it (outside the buttons) expands into
/// `RegularNowPlaying` via `ExpandableNowPlaying`. Composed from `CompactArtwork` and
/// `CompactChrome` so this standalone, tab-bar-docked copy shares the exact same layout math as
/// the copy inside `ExpandableNowPlaying` (which mounts those two pieces independently), and the
/// two can never visually drift apart.
struct CompactNowPlaying: View {
    @Binding var expanded: Bool
    var hideArtworkOnExpanded: Bool = true
    var animationNamespace: Namespace.ID?
    var marqueesActive = true
    var marqueeRestartToken = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if !hideArtworkOnExpanded || !expanded {
                CompactArtwork(animationNamespace: animationNamespace)
            }
            CompactChrome(marqueesActive: marqueesActive, marqueeRestartToken: marqueeRestartToken)
        }
    }
}

extension PlayerButtonConfig {
    static var miniPlayer: Self {
        Self(size: 44, tint: Color.transparentWhite)
    }
}
