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

    var expandableNowPlaying: some View {
        GeometryReader {
            let size = $0.size
            ZStack(alignment: .top) {
                NowPlayingBackground(colors: colors, expanded: expanded, isFullExpanded: isFullyExpanded)
                // A single if/else (rather than two independently-opacity-toggled views that
                // each internally condition their own artwork) guarantees SwiftUI mounts exactly
                // one `.artwork` matchedGeometryEffect source at a time — two separately-managed
                // conditionals sharing one boolean can transiently disagree during a transition
                // and briefly leave both mounted, which crashes with "Multiple inserted views in
                // matched geometry group ... isSource: true".
                if expanded {
                    RegularNowPlaying(size: size, colors: colors, animationNamespace: animationNamespace)
                        .transition(.opacity)
                } else {
                    CompactNowPlaying(expanded: $expanded, animationNamespace: animationNamespace)
                        .transition(.opacity)
                }
                ProgressTracker(progress: progressTrackState)
            }
            .frame(height: expanded ? nil : NowPlayingLayout.compactHeight, alignment: .top)
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
        withAnimation(.playerExpandAnimation) {
            if (translation + velocity) > (viewSize.height * 0.3) {
                expanded = false
                resetStackedWithAnimation()
            } else {
                stacked(progress: 1, withAnimation: true)
            }
            offsetY = 0
        }
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
