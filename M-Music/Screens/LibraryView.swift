import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var albumZoomNamespace

    let recent: [Album] = [
        TestModels.TooFastToDieJP,
        TestModels.Diluvium,
        TestModels.TooFastToDie,
        TestModels.Omnivium,
        TestModels.OmniviumDlx,
        TestModels.BleedTheFuture
    ]

    var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // MARK: Navigation Rows
                        VStack(spacing: 0) {
                            LibraryNavigationRow(title: "Playlists", icon: "music.note.list") {
                                PlaylistsListView()
                            }
                            rowDivider
                            LibraryNavigationRow(title: "Artists", icon: "music.mic") {
                                ArtistsListView()
                            }
                            rowDivider
                            LibraryNavigationRow(title: "Albums", icon: "square.stack") {
                                AlbumsListView()
                            }
                            rowDivider
                            LibraryNavigationRow(title: "Songs", icon: "music.note") {
                                SongsListView()
                            }
                        }
                        .padding(.horizontal, 16)

                        Text("Recently played")
                            .font(.system(size: 20))
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 18)

                        recentAlbumsGrid
                    }
                    .padding(.top, 8)
                }
                .environment(\.colorScheme, colorScheme)
                .navigationTitle("Library")
                .toolbar {
                    plusButton
                    settingsButton
                }
            }
            .environment(\.colorScheme, colorScheme)
        }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 40)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var recentAlbumsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(Array(recent.enumerated()), id: \.offset) { _, album in
                NavigationLink(destination: AlbumView(album: album, zoomNamespace: albumZoomNamespace)) {
                    AlbumCardView(album: album, zoomNamespace: albumZoomNamespace)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    struct LibraryNavigationRow<Destination: View>: View {
        let title: LocalizedStringKey
        let icon: String
        @ViewBuilder let destination: () -> Destination

        var body: some View {
            NavigationLink(destination: destination) {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 24, alignment: .center)

                    Text(title)
                        .font(.title3)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                Menu {
                    NavigationLink(destination: ServerSettingsView()) {
                        Label("Server", systemImage: "server.rack")
                    }
                    NavigationLink(destination: PlaybackSettingsView()) {
                        Label("Playback", systemImage: "play.circle")
                    }
                    NavigationLink(destination: DownloadsSettingsView()) {
                        Label("Downloads", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.primary)
                }
            }
        }
}

#Preview {
    LibraryView()
}
