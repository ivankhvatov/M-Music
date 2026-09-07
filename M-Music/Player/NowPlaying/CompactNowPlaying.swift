import SwiftUI

/// The collapsed mini player row — artwork, marquee title/artist, and play/pause + forward
/// buttons — docked into the tab bar. Tapping it (outside the buttons) expands into
/// `RegularNowPlaying` via `ExpandableNowPlaying`.
struct CompactNowPlaying: View {
    @ObservedObject private var player = PlayerManager.shared
    @Binding var expanded: Bool
    var hideArtworkOnExpanded: Bool = true
    /// Only the copy of this view living inside `ExpandableNowPlaying` (paired there with
    /// `RegularNowPlaying`'s artwork) needs this — pass `nil` for a standalone copy like the
    /// tab-bar-docked one in `MainView`. A `matchedGeometryEffect` with no destination is a
    /// permanently-mounted "source" for its id, and `.tabViewBottomAccessory` content can get
    /// transiently re-hosted by the system across tab switches — briefly producing two live
    /// sources for the same id and crashing SwiftUI ("Multiple inserted views ... isSource:
    /// true"). Keeping the effect scoped to just the paired instance avoids that.
    var animationNamespace: Namespace.ID?
    @State private var forwardAnimationTrigger: PlayerButtonTrigger = .one(bouncing: false)
    @State private var viewWidth: CGFloat = .zero

    var body: some View {
        nowPlaying
            .frame(height: NowPlayingLayout.compactHeight)
            .contentShape(.rect)
            .transformEffect(.identity)
            .onTapGesture {
                withAnimation(.playerExpandAnimation) {
                    expanded = true
                }
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
}

private extension CompactNowPlaying {
    @ViewBuilder
    func artwork(cornerRadius: CGFloat) -> some View {
        if !hideArtworkOnExpanded || !expanded {
            if let animationNamespace {
                TrackArtworkView(url: player.artworkURL, cornerRadius: cornerRadius)
                    .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
            } else {
                TrackArtworkView(url: player.artworkURL, cornerRadius: cornerRadius)
            }
        }
    }

    var inlinedBottomAccessory: Bool {
        let padding = UIScreen.size.width - viewWidth
        return padding > 60
    }

    var nowPlaying: some View {
        HStack(spacing: 0) {
            artwork(cornerRadius: 5)
                .frame(width: 30, height: 30)
            VStack(spacing: 0) {
                MarqueeText(text: player.currentTrack?.title ?? String(localized: "Not Playing"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 13, weight: .semibold))
                MarqueeText(text: player.currentTrack?.artist ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .geometryGroup()
            .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                PlayerButton(
                    label: { PlayerButtonLabel(type: player.isPlaying ? .pause : .play, size: 16) },
                    onEnded: { player.togglePlayPause() }
                )
                if !inlinedBottomAccessory {
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
    }
}

extension PlayerButtonConfig {
    static var miniPlayer: Self {
        Self(size: 44, tint: Color.transparentWhite)
    }
}
