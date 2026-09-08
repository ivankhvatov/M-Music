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
                }
            }
            .onPreferenceChange(NowPlayingExpandProgressPreferenceKey.self) { [$expandProgress] value in
                guard expandProgress != value else { return }
                $expandProgress.wrappedValue = value
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
                // A single if/else (rather than two independently-opacity-toggled views that
                // each internally condition their own artwork) guarantees SwiftUI mounts exactly
                // one `.artwork` matchedGeometryEffect source at a time — two separately-managed
                // conditionals sharing one boolean can transiently disagree during a transition
                // and briefly leave both mounted, which crashes with "Multiple inserted views in
                // matched geometry group ... isSource: true". Gated on `expanded` directly (not
                // the delayed material threshold above) so the artwork's matchedGeometryEffect
                // handoff runs across the full collapse, in step with the pill's own shape.
                //
                // No `.opacity` in these transitions: it applies to the *whole* view being
                // inserted/removed, including the artwork inside it — but the artwork's own
                // continuity is already handled by `matchedGeometryEffect`, which only
                // interpolates position/size, not alpha. Layering an independent opacity fade on
                // top fights that: the outgoing view's alpha ramps down while the incoming view's
                // ramps up, and since they're two distinct instances the two ramps don't visually
                // cancel out — the artwork reads as snapping away, then fading back in, instead of
                // just continuously shrinking. `.scale` alone still gives the rest of the content
                // (grip, controls) a pop-in/out on mount without touching alpha.
                if expanded {
                    RegularNowPlaying(size: size, colors: colors, animationNamespace: animationNamespace, onCollapse: collapse)
                        .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
                } else {
                    CompactNowPlaying(expanded: $expanded, animationNamespace: animationNamespace)
                        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
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
