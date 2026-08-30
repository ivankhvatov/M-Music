import SwiftUI

struct MainView: View {
    @State private var selectedTab : Int = 0
    @State private var isPlaying : Bool = false
    @State private var expandPlayer : Bool = false
    
    @Namespace private var animation
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                TabBar()
                    .tabViewBottomAccessory {
                        MiniPlayerView()
                            .onTapGesture {
                                expandPlayer.toggle()
                            }
                            .matchedTransitionSource(id: "MINIPLAYER", in: animation)
                            .environment(\.colorScheme, colorScheme)
                    }
                    .tabBarMinimizeBehavior(.never)
            }
            else {
                TabBar()
            }
        }
        .environment(\.colorScheme, colorScheme)
        .fullScreenCover(isPresented: $expandPlayer,) {
            Player()
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
    
    func Player() -> some View {
        PlayerView()
            .navigationTransition(.zoom(sourceID: "MINIPLAYER", in: animation))
    }
}

#Preview {
    MainView()
}
