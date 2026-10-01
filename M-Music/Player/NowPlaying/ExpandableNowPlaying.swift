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
    /// Drives the chrome crossfade below — kept separate from `expandProgress`, which also tracks
    /// the interactive drag-to-dismiss gesture pixel-by-pixel as the user's finger moves. Chrome
    /// should only start crossfading once a collapse is actually committed (released past the
    /// threshold, or the grip tapped), not merely previewed by dragging partway down and holding.
    /// `stacked(progress:withAnimation:)` only touches this alongside `progressTrackState` when
    /// `withAnimation` is true — i.e. never from the interactive, per-pixel gesture updates — so it
    /// stays pinned at its pre-drag value for the whole interactive portion of the gesture and only
    /// animates once the gesture ends in a real committed transition.
    @State private var chromeProgress: CGFloat = 0.0
    /// Drives the pill's *shape* — frame height, corner radius, the mini/full artwork swap, and
    /// `NowPlayingBackground`'s own matching shape — kept separate from the `expanded` binding
    /// itself so a view that's born already `expanded` (see `expandNow()`'s doc comment) still
    /// starts this at `false` and animates it to `true` a moment later, instead of snapping
    /// straight to its final geometry on the very first frame. A plain SwiftUI state change can
    /// only animate a transition an existing view lives through, never the geometry a view is
    /// *born* with — so `expanded` itself (which really can start `true`) can't drive this
    /// directly, or the whole shape morph (and the artwork's `matchedGeometryEffect` handoff,
    /// which depends on it) would be skipped in favor of the overlay's own plain insertion fade.
    @State private var isShapeExpanded = false
    /// Bumped every time an expand starts, so the expanded chrome's marquees always begin scrolling
    /// from their start position instead of wherever their clock happened to be.
    @State private var marqueeRestartToken = 0
    /// Bumped every time a collapse starts — the same, for the mini player's marquees.
    @State private var compactMarqueeRestartToken = 0
    /// 1 for full color, 0 for grayscale — see `NowPlayingBackground.saturation`. Reset to 1
    /// instantly whenever an expand starts (so it's never mid-fade the next time it's needed) and
    /// animated down to 0 by `collapse()`.
    @State private var backgroundSaturation: CGFloat = 1
    /// Whether the expanded player is showing the up-next queue (toggled from its bottom row):
    /// the artwork shrinks to the top left and the title/artist move beside it, above the list.
    @State private var showsQueue = false
    @State private var colors: [Color] = [.gray]
    @Namespace private var animationNamespace

    var body: some View {
        expandableNowPlaying
            .onAppear {
                // This view can mount already `expanded` — `MainView` defers mounting it until
                // shortly after launch (to skip its one-time SwiftUI setup cost when nothing's
                // loaded yet), but mounts it immediately if the mini player is tapped before that
                // timer fires. `.onChange(of: expanded)` below only fires on a *transition*, so
                // without this, a view that's born already expanded would never run the setup
                // that puts it in its expanded visual state: `progressTrackState`/`chromeProgress`
                // would stay at their zero default, leaving `isFullyCollapsed` permanently true —
                // the view renders at opacity 0 with hit-testing off (see `expandableNowPlaying`),
                // i.e. invisible and untappable despite `expanded` being true — and the docked mini
                // player's own artwork copy stays hidden too (`accessoryVisible` never flips).
                guard expanded else { return }
                expandNow()
            }
            .onChange(of: expanded) {
                if expanded {
                    expandNow()
                } else {
                    compactMarqueeRestartToken &+= 1
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

    /// Whether the chromes' marquees should be scrolling: whenever any of the player is on screen.
    /// (The chromes stay mounted while collapsed at opacity 0; this keeps their timelines paused.)
    var marqueesActive: Bool {
        !isFullyCollapsed
    }

    /// Gates *only* `NowPlayingBackground`'s material (glass vs. colorful fill) — deliberately
    /// separate from the Regular/Compact content switch below, which must stay tied to
    /// `isShapeExpanded` directly. The content switch is what mounts/unmounts the two
    /// `matchedGeometryEffect` artwork views, so it has to happen immediately, in the same
    /// animation transaction as the pill's own shape change, for that morph to interpolate
    /// smoothly across the whole collapse — gating it on this threshold instead delayed the mount
    /// swap until the container had already shrunk nearly to mini size, leaving nothing left to
    /// visibly morph (the artwork just rode the shrinking layout straight down instead of
    /// animating toward the mini artwork's actual position). The background fill has no such
    /// constraint, so it alone stays showing the expanded/colorful look for most of the shrink and
    /// only swaps to real Liquid Glass in the final stretch.
    var showsExpandedMaterial: Bool {
        isShapeExpanded || expandProgress > Const.collapseMorphThreshold
    }

    var expandableNowPlaying: some View {
        GeometryReader {
            let size = $0.size
            ZStack(alignment: .top) {
                NowPlayingBackground(
                    colors: colors,
                    expanded: isShapeExpanded,
                    showsExpandedContent: showsExpandedMaterial,
                    isFullExpanded: isFullyExpanded,
                    saturation: backgroundSaturation
                )
                // Chrome (grip + controls, or marquee + buttons) — both always mounted and
                // cross-faded via `chromeProgress`, rather than swapped through an if/else with a
                // `.transition()`. A `.transition()` here only pops in/out over whatever fraction
                // of the ambient animation SwiftUI itself decides to spend on the mount/unmount —
                // which in practice settled almost immediately, long before the artwork (driven by
                // `matchedGeometryEffect`, which tracks the real geometry handoff frame by frame)
                // had finished shrinking. Tying opacity to `chromeProgress` — which only moves on
                // committed, animated transitions, never on the interactive drag-to-dismiss preview
                // — keeps the chrome's fade locked to the player's actual, real-time expand/collapse
                // progress instead of racing ahead of it, and keeps it from starting to crossfade
                // just because the player was dragged partway down and held. Safe to keep both
                // always mounted (unlike the artwork below): neither branch contains a
                // `matchedGeometryEffect` descendant, so there's no risk of two simultaneous sources
                // for the same id.
                RegularChrome(size: size, colors: colors, onCollapse: collapse, marqueesActive: marqueesActive, marqueeRestartToken: marqueeRestartToken, showsQueue: $showsQueue)
                    .environment(\.playerButtonSymbolTransitions, expanded)
                    .opacity(chromeProgress)
                    .allowsHitTesting(expanded)
                CompactChrome(expanded: $expanded, marqueesActive: marqueesActive, marqueeRestartToken: compactMarqueeRestartToken)
                    .environment(\.playerButtonSymbolTransitions, !expanded)
                    .opacity(1 - chromeProgress)
                    .allowsHitTesting(!expanded)
                // Artwork alone — a single `matchedGeometryEffect` source at a time (two
                // independently-mounted sources for the same id crashes SwiftUI with "Multiple
                // inserted views in matched geometry group ... isSource: true"). Swapped on
                // `isShapeExpanded` directly (not the delayed material threshold above, and not
                // the raw `expanded` binding — see its doc comment) so the handoff runs across the
                // full collapse/expand, in step with the pill's own shape.
                //
                // `.transition(.scale(scale: 1))` on both branches — a transition that is, by
                // construction, visually a no-op (scaling by a factor of 1 changes nothing) but is
                // still a *real* `AnyTransition`, unlike `.identity`. That distinction matters:
                //
                // - Leaving no explicit `.transition()` falls back to SwiftUI's default, which is
                //   `.opacity`. That fought `matchedGeometryEffect`: the outgoing view's removal
                //   got cut short (SwiftUI doesn't keep a matchedGeometryEffect source around to
                //   finish fading), so the artwork vanished instantly at the start of a collapse,
                //   then the incoming view's own fade-in played out normally on top of the
                //   geometry handoff — an instant disappear followed by a fade back in.
                // - Switching to `.transition(.identity)` removed that opacity ramp, but also
                //   dropped this mount/unmount out of the animated transaction entirely — SwiftUI
                //   treats `.identity` as "nothing to animate here" and applies it immediately,
                //   which took `matchedGeometryEffect`'s own position/size interpolation down with
                //   it, so the artwork snapped straight to its expanded/collapsed frame instead of
                //   morphing.
                // - `.scale(scale: 1)` keeps the view inside the animated transaction (so
                //   `matchedGeometryEffect` still has an animation to interpolate across) while
                //   never actually changing how the view looks at any point, so there's no opacity
                //   or scale artifact layered on top of the geometry handoff.
                if isShapeExpanded {
                    RegularArtwork(size: size, animationNamespace: animationNamespace, showsQueue: showsQueue)
                        .transition(.scale(scale: 1))
                } else {
                    CompactArtwork(animationNamespace: animationNamespace)
                        .transition(.scale(scale: 1))
                }
                ProgressTracker(progress: progressTrackState)
            }
            .frame(height: isShapeExpanded ? nil : NowPlayingLayout.compactHeight, alignment: .top)
            // `NowPlayingBackground` only clips its own fill to the pill/rounded-rect shape —
            // its ZStack siblings (the Compact/Regular content, scaling in via `.transition`)
            // aren't clipped by that on their own, so a mid-animation frame where the content's
            // own scale hasn't tracked the container's animating height exactly could show it
            // poking past the background's rounded corners. Clipping the whole stack to the same
            // shape guarantees content never renders outside the background's current bounds,
            // however the two animations line up frame to frame.
            .clipShape(.rect(cornerRadius: NowPlayingBackground.cornerRadius(expanded: isShapeExpanded, isFullExpanded: isFullyExpanded)))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, insets.bottom)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .offset(y: offsetY)
            .gesture(
                PanGesture(
                    onChange: { handleGestureChange(value: $0, viewSize: size) },
                    onEnd: { handleGestureEnd(value: $0, viewSize: size) },
                    deferring: PanGesture.reorderHandleTag,
                    requiresVerticalMovement: true
                )
            )
            .ignoresSafeArea()
        }
        // `.animation(nil, ...)`: without it, this opacity swap picks up whatever
        // `.playerExpandAnimation` is ambient at the time (the same one driving the pill's own
        // shape morph) and fades in across that full duration — reading as the pill materializing
        // *while* it grows, on top of the shape morph, rather than the shape alone morphing into
        // an already-solid pill. `isFullyCollapsed` flips the instant a real expand/collapse
        // starts (as soon as `expandProgress` leaves/reaches exactly 0), so cutting the animation
        // here doesn't cost any actual cross-fade — same reasoning as `NowPlayingBackground`'s own
        // `.animation(nil, value: showsExpandedContent)`.
        .opacity(isFullyCollapsed ? 0 : 1)
        .animation(nil, value: isFullyCollapsed)
        .allowsHitTesting(!isFullyCollapsed)
    }

    func handleGestureChange(value: PanGesture.Value, viewSize: CGSize) {
        guard expanded, !showsQueue else { return }
        let translation = max(value.translation.height, 0)
        offsetY = translation
        windowProgress = max(min(translation / viewSize.height, 1), 0)
        stacked(progress: 1 - windowProgress, withAnimation: false)
    }

    func handleGestureEnd(value: PanGesture.Value, viewSize: CGSize) {
        guard expanded, !showsQueue else { return }
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
        // Delayed briefly (so the shape has visibly started shrinking, colorful, before the fade
        // begins) and, once it does begin, shorter than `playerExpandAnimation` — both started in
        // their own transaction, not the shape morph's — so the gradient has already faded to gray
        // by the time `showsExpandedMaterial` flips over to Liquid Glass near the end of the
        // shrink: a beat of color, then a desaturate, then the swap to glass.
        withAnimation(.smooth(duration: Const.saturationFadeDuration).delay(Const.saturationFadeDelay)) {
            backgroundSaturation = 0
        }
    }

    /// Puts the view in its expanded visual state — shared by the real `expanded` transition
    /// (`.onChange`) and by mounting already-expanded (`.onAppear`), so both end up in exactly
    /// the same state, animated the exact same way: `isShapeExpanded` starts (or, for the
    /// already-expanded case, *stays*) at its collapsed value for this view's very first frame,
    /// and only flips here — inside an explicit, self-contained animation — which is what makes
    /// the pill actually grow via `.playerExpandAnimation` instead of the overlay's own insertion
    /// just fading the final, already-expanded frame into view.
    func expandNow() {
        marqueeRestartToken &+= 1
        backgroundSaturation = 1
        withAnimation(.playerExpandAnimation) {
            isShapeExpanded = true
        }
        stacked(progress: 1, withAnimation: true)
        accessoryVisible = false
    }

    func stacked(progress: CGFloat, withAnimation: Bool) {
        if withAnimation {
            SwiftUI.withAnimation(.playerExpandAnimation) {
                progressTrackState = progress
                chromeProgress = progress
            }
        } else {
            progressTrackState = progress
        }
    }

    func resetStackedWithAnimation() {
        withAnimation(.playerExpandAnimation) {
            progressTrackState = 0
            chromeProgress = 0
            isShapeExpanded = false
        }
    }

    /// Branches on `isShapeExpanded`, not the raw `expanded` binding — see its doc comment.
    var insets: EdgeInsets {
        if isShapeExpanded {
            return .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
        return .init(
            top: 0,
            leading: collapsedFrame.minX,
            bottom: UIScreen.size.height - collapsedFrame.maxY,
            trailing: UIScreen.size.width - collapsedFrame.maxX
        )
    }

    /// Colours only need a coarse look at the artwork, so this reads a small decoded tier (the
    /// dominant-colour pass resamples to 40×40 anyway) and does the pixel work off the main
    /// actor; only the finished palette is assigned here, once.
    func updateColors() async {
        guard let url = player.artworkURL,
              let uiImage = await ImageCache.shared.load(url, maxPixelSize: ImageCache.colorSamplingMaxPixelSize)
        else {
            colors = [.gray]
            return
        }
        let palette = await Task.detached(priority: .userInitiated) {
            let vivid = uiImage.dominantColors(count: 3)
                .map { $0.darkened() }
                .reducedContrast(by: 0.2)
            // Both ratios below are measured against the same single average — the artwork's
            // overall look, including the near-black/near-white/desaturated pixels the
            // dominant-colour pass above skips — so the backdrop reads as a natural extension of
            // the cover's own tone rather than an independently tuned effect.
            guard let artworkAverage = uiImage.averageColor() else {
                return vivid.map { $0.darkened(by: 0.75) }
            }
            // Pin the palette's average saturation a little above the artwork's own average — a
            // livelier backdrop than the artwork itself (which, averaged over the whole cover,
            // reads more muted than any single dominant color in it) — before pinning lightness,
            // since that scaling is what's relied on to land the *exact* final lightness.
            let vivider = vivid.scaledToAverageSaturation(artworkAverage.saturation * Const.backdropSaturationRatio)
            // Pin the palette's average lightness a little under the artwork's own average — so
            // the backdrop follows the artwork's tone, lightening or darkening the picked colors
            // as needed, but always sits slightly darker than it.
            return vivider.scaledToAverageLightness(artworkAverage.perceivedLightness * Const.backdropLightnessRatio)
        }.value
        guard !Task.isCancelled else { return }
        colors = palette.isEmpty ? [.gray] : palette
    }

    enum Const {
        /// How light the backdrop palette's average is relative to the artwork's own average
        /// lightness — under 1 so the background reads slightly darker than the cover.
        static let backdropLightnessRatio: CGFloat = 0.8

        /// How saturated the backdrop palette's average is relative to the artwork's own average
        /// saturation — over 1 so the background reads slightly more vivid than the cover.
        static let backdropSaturationRatio: CGFloat = 1.3

        /// Below this fraction of `expandProgress`, a collapse switches the content/material over
        /// to the mini player's look. Small on purpose — the morph itself should only occupy the
        /// last stretch of the shrink, not race it the whole way down.
        static let collapseMorphThreshold: CGFloat = 0.15

        /// How long a collapse waits before the background starts desaturating — just long enough
        /// that the shrink is visibly under way, still in full color, before the fade begins.
        static let saturationFadeDelay: TimeInterval = 0.05

        /// How long the background then takes to desaturate to gray. `saturationFadeDelay +
        /// saturationFadeDuration` is kept well under `playerExpandAnimationDuration` so the fade
        /// — delay included — finishes before `collapseMorphThreshold` is reached and the
        /// background swaps over to Liquid Glass.
        static let saturationFadeDuration: TimeInterval = 0.12
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
