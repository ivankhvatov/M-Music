import SwiftUI

struct MainView: View {
    @State private var selectedTab : Int = 0
    @State private var expandPlayer : Bool = false
    @State private var nowPlayingFrame: CGRect = .zero

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TabBar()
            .tabViewBottomAccessory {
                CompactNowPlaying(expanded: $expandPlayer)
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
                ExpandableNowPlaying(expanded: $expandPlayer, collapsedFrame: nowPlayingFrame)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
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
