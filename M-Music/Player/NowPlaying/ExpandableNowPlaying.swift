import SwiftUI

enum PlayerMatchedGeometry {
    case artwork
}

/// Hosts both the collapsed mini player and the full-screen Now Playing view, morphing between
/// them via `matchedGeometryEffect` and a drag-to-dismiss pan gesture — the same mechanism Apple
/// Music uses for its tab-bar-docked player.
struct ExpandableNowPlaying: View {
    @Binding var expanded: Bool
    var collapsedFrame: CGRect
    /// Set to `false` the instant the expand animation starts, `true` the instant the collapse
    /// animation settles — lets `MainView` hide the real `.tabViewBottomAccessory` as soon as this
    /// view starts taking over the screen, and only bring it back once this view has fully handed
    /// off to it, so the two are never both visible at once.
    @Binding var accessoryVisible: Bool
    @ObservedObject private var player = PlayerManager.shared
    @State private var offsetY: CGFloat = 0.0
    @State private var windowProgress: CGFloat = 0.0
    @State private var progressTrackState: CGFloat = 0.0
    @State private var expandProgress: CGFloat = 0.0
    @State private var colors: [Color] = [.gray]
    @Namespace private var animationNamespace

    var body: some View {
        expandableNowPlaying
            .onChange(of: expanded) {
                if expanded {
                    stacked(progress: 1, withAnimation: true)
                    accessoryVisible = false
                }
            }
            .onPreferenceChange(NowPlayingExpandProgressPreferenceKey.self) { [$expandProgress] value in
                guard expandProgress != value else { return }
                $expandProgress.wrappedValue = value
            }
            .onChange(of: isFullyCollapsed) { _, isFullyCollapsed in
                guard isFullyCollapsed else { return }
                accessoryVisible = true
            }
            .task(id: player.artworkURL) {
                await updateColors()
            }
    }
}

private extension ExpandableNowPlaying {
    var isFullyExpanded: Bool {
        expandProgress >= 1
    }

    var isFullyCollapsed: Bool {
        expandProgress.isZero
    }

    /// Gates *only* `NowPlayingBackground`'s material (glass vs. colorful fill) — deliberately
    /// separate from the Regular/Compact content switch below, which must stay tied to `expanded`
    /// directly. The content switch is what mounts/unmounts the two `matchedGeometryEffect`
    /// artwork views, so it has to happen immediately, in the same animation transaction as the
    /// pill's own shape change, for that morph to interpolate smoothly across the whole collapse
    /// — gating it on this threshold instead delayed the mount swap until the container had
    /// already shrunk nearly to mini size, leaving nothing left to visibly morph (the artwork just
    /// rode the shrinking layout straight down instead of animating toward the mini artwork's
    /// actual position). The background fill has no such constraint, so it alone stays showing
    /// the expanded/colorful look for most of the shrink and only swaps to real Liquid Glass in
    /// the final stretch.
    var showsExpandedMaterial: Bool {
        expanded || expandProgress > Const.collapseMorphThreshold
    }

    var expandableNowPlaying: some View {
        GeometryReader {
            let size = $0.size
            ZStack(alignment: .top) {
                NowPlayingBackground(
                    colors: colors,
                    expanded: expanded,
                    showsExpandedContent: showsExpandedMaterial,
                    isFullExpanded: isFullyExpanded
                )
                // Chrome (grip + controls, or marquee + buttons) — both always mounted and
                // cross-faded via `expandProgress` directly, rather than swapped through an
                // if/else with a `.transition()`. A `.transition()` here only pops in/out over
                // whatever fraction of the ambient animation SwiftUI itself decides to spend on
                // the mount/unmount — which in practice settled almost immediately, long before
                // the artwork (driven by `matchedGeometryEffect`, which tracks the real geometry
                // handoff frame by frame) had finished shrinking. Tying opacity straight to
                // `expandProgress` — the same continuously-updated signal the artwork's container
                // and material already key off — keeps the chrome's fade locked to the player's
                // actual, real-time expand/collapse progress instead of racing ahead of it. Safe
                // to keep both always mounted (unlike the artwork below): neither branch contains
                // a `matchedGeometryEffect` descendant, so there's no risk of two simultaneous
                // sources for the same id.
                RegularChrome(size: size, colors: colors, onCollapse: collapse)
                    .opacity(expandProgress)
                    .allowsHitTesting(expanded)
                CompactChrome(expanded: $expanded)
                    .opacity(1 - expandProgress)
                    .allowsHitTesting(!expanded)
                // Artwork alone — a single `matchedGeometryEffect` source at a time (two
                // independently-mounted sources for the same id crashes SwiftUI with "Multiple
                // inserted views in matched geometry group ... isSource: true"). Swapped on
                // `expanded` directly (not the delayed material threshold above) so the handoff
                // runs across the full collapse, in step with the pill's own shape. No
                // `.transition()` here — matchedGeometryEffect handles its own continuity
                // (position/size only, no alpha), so the swap itself can just be instant and the
                // artwork never disappears, even for a frame.
                if expanded {
                    RegularArtwork(size: size, animationNamespace: animationNamespace)
                } else {
                    CompactArtwork(animationNamespace: animationNamespace)
                }
                ProgressTracker(progress: progressTrackState)
            }
            .frame(height: expanded ? nil : NowPlayingLayout.compactHeight, alignment: .top)
            // `NowPlayingBackground` only clips its own fill to the pill/rounded-rect shape —
            // its ZStack siblings (the Compact/Regular content, scaling in via `.transition`)
            // aren't clipped by that on their own, so a mid-animation frame where the content's
            // own scale hasn't tracked the container's animating height exactly could show it
            // poking past the background's rounded corners. Clipping the whole stack to the same
            // shape guarantees content never renders outside the background's current bounds,
            // however the two animations line up frame to frame.
            .clipShape(.rect(cornerRadius: NowPlayingBackground.cornerRadius(expanded: expanded, isFullExpanded: isFullyExpanded)))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, insets.bottom)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .offset(y: offsetY)
            .gesture(
                PanGesture(
                    onChange: { handleGestureChange(value: $0, viewSize: size) },
                    onEnd: { handleGestureEnd(value: $0, viewSize: size) }
                )
            )
            .ignoresSafeArea()
        }
        .opacity(isFullyCollapsed ? 0 : 1)
        .allowsHitTesting(!isFullyCollapsed)
    }

    func handleGestureChange(value: PanGesture.Value, viewSize: CGSize) {
        guard expanded else { return }
        let translation = max(value.translation.height, 0)
        offsetY = translation
        windowProgress = max(min(translation / viewSize.height, 1), 0)
        stacked(progress: 1 - windowProgress, withAnimation: false)
    }

    func handleGestureEnd(value: PanGesture.Value, viewSize: CGSize) {
        guard expanded else { return }
        let translation = max(value.translation.height, 0)
        let velocity = value.velocity.height / 5
        if (translation + velocity) > (viewSize.height * 0.3) {
            collapse()
        } else {
            withAnimation(.playerExpandAnimation) {
                stacked(progress: 1, withAnimation: true)
                offsetY = 0
            }
        }
    }

    /// Same collapse the drag-to-dismiss gesture performs past its threshold — shared so tapping
    /// the grip does the identical animated transition instead of just flipping `expanded`, which
    /// would leave `progressTrackState` (and so `isFullyCollapsed`/hit-testing) stuck as if still
    /// expanded. Self-contained (wraps its own animation) so it works the same regardless of
    /// caller context.
    func collapse() {
        withAnimation(.playerExpandAnimation) {
            expanded = false
            offsetY = 0
        }
        resetStackedWithAnimation()
    }

    func stacked(progress: CGFloat, withAnimation: Bool) {
        if withAnimation {
            SwiftUI.withAnimation(.playerExpandAnimation) {
                progressTrackState = progress
            }
        } else {
            progressTrackState = progress
        }
    }

    func resetStackedWithAnimation() {
        withAnimation(.playerExpandAnimation) {
            progressTrackState = 0
        }
    }

    var insets: EdgeInsets {
        if expanded {
            return .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
        return .init(
            top: 0,
            leading: collapsedFrame.minX,
            bottom: UIScreen.size.height - collapsedFrame.maxY,
            trailing: UIScreen.size.width - collapsedFrame.maxX
        )
    }

    func updateColors() async {
        guard let url = player.artworkURL, let uiImage = await ImageCache.shared.load(url) else {
            colors = [.gray]
            return
        }
        let dominant = uiImage.dominantColors(count: 3)
            .map { $0.saturated(by: 1.35).darkened(by: 0.75) }
            .reducedContrast(by: 0.3)
        colors = dominant.isEmpty ? [.gray] : dominant
    }

    enum Const {
        /// Below this fraction of `expandProgress`, a collapse switches the content/material over
        /// to the mini player's look. Small on purpose — the morph itself should only occupy the
        /// last stretch of the shrink, not race it the whole way down.
        static let collapseMorphThreshold: CGFloat = 0.15
    }
}

extension Animation {
    static let playerExpandAnimationDuration: TimeInterval = 0.3
    static var playerExpandAnimation: Animation {
        .smooth(duration: playerExpandAnimationDuration, extraBounce: 0)
    }
}

private struct ProgressTracker: View, Animatable {
    var progress: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .preference(key: NowPlayingExpandProgressPreferenceKey.self, value: progress)
    }
}
