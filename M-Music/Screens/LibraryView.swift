import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    let recent: [Album] = [
        TestModels.album,
        TestModels.album,
        TestModels.album,
        TestModels.album,
    ]
    
    var body: some View {
            NavigationStack {
                List {
                    // MARK: Navigation Rows
                    Group {
                        LibraryNavigationRow(title: "Playlists", icon: "music.note.list")
                        LibraryNavigationRow(title: "Artists", icon: "music.mic")
                        LibraryNavigationRow(title: "Albums", icon: "square.stack")
                        LibraryNavigationRow(title: "Tracks", icon: "music.note")
                    }
                    .listRowSeparator(.visible)
                    
                    Text("Recently played")
                        .font(.title2)
                        .padding(.bottom, -10)
                    
                }
                .environment(\.colorScheme, colorScheme)
                .listStyle(.plain)
                .navigationTitle("Library")
                .toolbar {
                    plusButton
                    settingsButton
                }
                
            }
            .environment(\.colorScheme, colorScheme)
        }
    
    struct LibraryNavigationRow: View {
        let title: LocalizedStringKey
        let icon: String
        
        var body: some View {
            NavigationLink(destination: Text(title)) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 24, alignment: .center)
                    
                    Text(title)
                        .font(.title3)
                }
                .padding(.vertical, 0)
            }
        }
    }
    
    @ToolbarContentBuilder
        private var plusButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.primary)
                }
            }
        }
    
    @ToolbarContentBuilder
        private var settingsButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.primary)
                }
            }
        }
}

#Preview {
    LibraryView()
}
