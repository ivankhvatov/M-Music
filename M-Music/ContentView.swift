import SwiftUI
import Combine
import Observation

/// Whether and how the full-screen player is presented — the state `MainView`'s overlay and
/// bottom accessory share. It lives here, observed only by the two small views that actually read
/// it (`NowPlayingAccessory`, `PlayerOverlay`), rather than as `@State` on `MainView`: every write
/// to `MainView`'s own state re-runs its whole `body` — the `TabView` and both of those — and a
/// single expand or collapse writes this state two or three times (the tap, the accessory hand-off,
/// the marquee restart), which put a long stall into the first frame of the animation and again
/// when the mini player took over at the end of a collapse.
@Observable
final class PlayerPresentation {
    static let shared = PlayerPresentation()

    var expanded = false
    var nowPlayingFrame: CGRect = .zero
    /// Set to `false` the instant the expand animation starts, `true` the instant the collapse
    /// animation settles — see `ExpandableNowPlaying`.
    var accessoryVisible = true
    /// Bumped when a collapse starts, so the docked mini player's marquees begin from their start
    /// position, in step with the ones inside the collapsing pill that hands off to them.
    var accessoryMarqueeRestartToken = 0
    /// Whether anything is loaded in the player (a track, or a radio station). The full-screen
    /// player overlay is only built once there is — see `PlayerOverlay`. Fed by a de-duplicated
    /// publisher rather than by observing `PlayerManager`: that publishes `currentTime` twice a
    /// second, and observing it would re-run whatever read it on every tick.
    var hasNowPlaying = false
    /// Flips on shortly after launch. The system-rendered mini player (the bottom accessory) is all
    /// that's visible at first, so the full-screen player's large subtree — and the one-time
    /// SwiftUI setup cost of its many view types — is built once the first frames are out of the
    /// way instead of inside them. Expanding earlier than that still works: `expanded` mounts it.
    var overlayReady = false
}

struct MainView: View {
    @State private var selectedTab : Int = 0

    private static let hasNowPlayingPublisher = Publishers
        .CombineLatest(PlayerManager.shared.$currentIndex, PlayerManager.shared.$currentRadioStation)
        .map { index, station in index != nil || station != nil }
        .removeDuplicates()

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TabBar()
            .tabViewBottomAccessory {
                NowPlayingAccessory()
            }
            .tabBarMinimizeBehavior(.never)
            .environment(\.colorScheme, colorScheme)
            .overlay {
                PlayerOverlay()
            }
            .onReceive(Self.hasNowPlayingPublisher) { PlayerPresentation.shared.hasNowPlaying = $0 }
            .task {
                try? await Task.sleep(for: .milliseconds(900))
                PlayerPresentation.shared.overlayReady = true
                // Once, at idle — not from each list screen's `.onAppear`, where the cache scans
                // (and the publish that follows them, which re-renders every observing screen)
                // landed in the middle of the push animation. `preload()` is guarded internally.
                try? await Task.sleep(for: .milliseconds(1500))
                await LibraryCacheStatus.shared.preload()
                // First use of the image cache creates its directories synchronously; do it here
                // rather than on the main thread when the first artwork view appears.
                await Task.detached(priority: .utility) { _ = ImageCache.shared }.value
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

/// The docked mini player in the tab bar's bottom accessory.
private struct NowPlayingAccessory: View {
    @Bindable private var presentation = PlayerPresentation.shared

    var body: some View {
        CompactNowPlaying(
            expanded: $presentation.expanded,
            marqueesActive: presentation.accessoryVisible,
            marqueeRestartToken: presentation.accessoryMarqueeRestartToken
        )
            // Hidden (not removed, so its geometry/layout stays reserved and stable) the
            // instant `ExpandableNowPlaying`'s own pill starts expanding, and shown again
            // only once that pill has fully handed back off to this real, system-rendered
            // accessory — see `accessoryVisible`'s doc comment on `ExpandableNowPlaying`.
            // `.animation(nil, ...)` because this is a hard cut tied to the *start*/*end*
            // of the other animation, not something that should itself animate.
            .environment(\.playerButtonSymbolTransitions, presentation.accessoryVisible)
            .opacity(presentation.accessoryVisible ? 1 : 0)
            .allowsHitTesting(presentation.accessoryVisible)
            .animation(nil, value: presentation.accessoryVisible)
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
                    guard new.origin.y != 0, presentation.nowPlayingFrame != new else { return }
                    presentation.nowPlayingFrame = new
                }
            )
    }
}

/// The full-screen player, mounted over the whole tab view.
private struct PlayerOverlay: View {
    @Bindable private var presentation = PlayerPresentation.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nothing to expand into until something's loaded, so don't build the full-screen
        // player yet: it's a large subtree (the expanded controls, an `AVRoutePickerView`,
        // the glass and gradient layers) whose one-time SwiftUI setup cost otherwise lands
        // in the first second after launch — on a fresh install with no server, that's
        // all of it wasted. It mounts (hidden, fully collapsed) the moment a track or
        // station loads, well before anyone can expand it.
        if (presentation.hasNowPlaying && presentation.overlayReady) || presentation.expanded {
            ExpandableNowPlaying(
                expanded: $presentation.expanded,
                collapsedFrame: presentation.nowPlayingFrame,
                accessoryVisible: $presentation.accessoryVisible
            )
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            // `.identity`, not the SwiftUI default (`.opacity`): tapping the mini player
            // before `overlayReady` flips can mount this view for the first time already
            // `expanded` (see `ExpandableNowPlaying`'s own `isShapeExpanded` doc comment),
            // in the same animated transaction as the tap. Left at the default, that
            // insertion itself fades the whole subtree in from 0→1 opacity — on top of,
            // and independent from, the pill's own shape morph, which is driven entirely
            // by that view's internal state and doesn't need (or want) this mount animated
            // at all. `.identity` makes the view appear instantly, already showing
            // whatever its own state says (collapsed and invisible, on this first frame),
            // and leaves the actual expand animation to start a moment later, from that
            // view's own `onAppear`.
            .transition(.identity)
        }
    }
}

#Preview {
    MainView()
}
