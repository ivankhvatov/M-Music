import SwiftUI
import Combine

struct MainView: View {
    @State private var selectedTab : Int = 0
    @State private var expandPlayer : Bool = false
    @State private var nowPlayingFrame: CGRect = .zero
    @State private var accessoryVisible = true
    /// Bumped when a collapse starts, so the docked mini player's marquees begin from their start
    /// position, in step with the ones inside the collapsing pill that hands off to them.
    @State private var accessoryMarqueeRestartToken = 0
    /// Whether anything is loaded in the player (a track, or a radio station). The full-screen
    /// player overlay below is only built once there is — see its comment. Kept as its own
    /// `@State`, fed by a de-duplicated publisher, rather than observing `PlayerManager` here:
    /// that publishes `currentTime` twice a second, and observing it would re-run this whole
    /// view (the `TabView` and both overlays) on every tick.
    @State private var hasNowPlaying = PlayerManager.shared.currentTrack != nil || PlayerManager.shared.isRadio
    /// Flips on shortly after launch. The system-rendered mini player (the bottom accessory) is all
    /// that's visible at first, so the full-screen player's large subtree — and the one-time
    /// SwiftUI setup cost of its many view types — is built once the first frames are out of the
    /// way instead of inside them. Expanding earlier than that still works: `expandPlayer` mounts it.
    @State private var overlayReady = false

    private static let hasNowPlayingPublisher = Publishers
        .CombineLatest(PlayerManager.shared.$currentIndex, PlayerManager.shared.$currentRadioStation)
        .map { index, station in index != nil || station != nil }
        .removeDuplicates()

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TabBar()
            .tabViewBottomAccessory {
                CompactNowPlaying(
                    expanded: $expandPlayer,
                    marqueesActive: accessoryVisible,
                    marqueeRestartToken: accessoryMarqueeRestartToken
                )
                    // Hidden (not removed, so its geometry/layout stays reserved and stable) the
                    // instant `ExpandableNowPlaying`'s own pill starts expanding, and shown again
                    // only once that pill has fully handed back off to this real, system-rendered
                    // accessory — see `accessoryVisible`'s doc comment on `ExpandableNowPlaying`.
                    // `.animation(nil, ...)` because this is a hard cut tied to the *start*/*end*
                    // of the other animation, not something that should itself animate.
                    .opacity(accessoryVisible ? 1 : 0)
                    .allowsHitTesting(accessoryVisible)
                    .animation(nil, value: accessoryVisible)
                    .onGeometryChange(
                        for: CGRect.self,
                        of: { $0.frame(in: .global).roundedToPoint },
                        action: { new in
                            // A bottom-docked tab-bar accessory's `.global` y-origin is never
                            // legitimately 0 (that's the top of the screen). At some point during
                            // a tab-switch transition, `.tabViewBottomAccessory` content's
                            // `.global` coordinate-space conversion can briefly go degenerate and
                            // report (0,0,width,height) — confirmed via instrumentation: real
                            // measurements like (21, 735, 360, 48) suddenly snapped to
                            // (0, 0, 360, 48) and got stuck oscillating around exactly that value,
                            // each write differing from the last only in float bit pattern, which
                            // re-triggers this callback forever (infinite loop, ~190% CPU).
                            // Rejecting the impossible reading outright is more robust than trying
                            // to dedupe it after the fact.
                            guard new.origin.y != 0, nowPlayingFrame != new else { return }
                            nowPlayingFrame = new
                        }
                    )
            }
            .tabBarMinimizeBehavior(.never)
            .environment(\.colorScheme, colorScheme)
            .overlay {
                // Nothing to expand into until something's loaded, so don't build the full-screen
                // player yet: it's a large subtree (the expanded controls, an `AVRoutePickerView`,
                // the glass and gradient layers) whose one-time SwiftUI setup cost otherwise lands
                // in the first second after launch — on a fresh install with no server, that's
                // all of it wasted. It mounts (hidden, fully collapsed) the moment a track or
                // station loads, well before anyone can expand it.
                if (hasNowPlaying && overlayReady) || expandPlayer {
                    ExpandableNowPlaying(
                        expanded: $expandPlayer,
                        collapsedFrame: nowPlayingFrame,
                        accessoryVisible: $accessoryVisible
                    )
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
                }
            }
            .onChange(of: expandPlayer) {
                if !expandPlayer { accessoryMarqueeRestartToken &+= 1 }
            }
            .onReceive(Self.hasNowPlayingPublisher) { hasNowPlaying = $0 }
            .task {
                try? await Task.sleep(for: .milliseconds(900))
                overlayReady = true
            }
    }

    func TabBar() -> some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                HomeView()
            }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: 1) {
                RadioView()
            }
            Tab("Library", systemImage: "music.note.square.stack.fill", value: 2) {
                LibraryView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) {
                SearchView()
            }
        }
        .tint(.red)
    }
}

#Preview {
    MainView()
}
