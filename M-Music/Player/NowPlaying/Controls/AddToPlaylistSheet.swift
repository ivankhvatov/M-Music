import SwiftUI

/// The sheet behind the player's "Add to playlist": every playlist as a row like the ones of
/// `PlaylistsListView`, ending in a checkmark that's checked when the song is in that playlist
/// already. Tapping a playlist that doesn't have it closes the sheet and adds the song to the end
/// of it; tapping one that does asks first, since that would add it a second time.
///
/// Adding is the presenter's business (`onAdd`) and goes on after the sheet has gone.
struct AddToPlaylistSheet: View {
    let song: Child
    let onAdd: (PlaylistSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    /// Which playlists have the song: the song ids each was last known to hold.
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    /// The order the playlists screen is set to.
    @AppStorage("playlistsList.sortField") private var sortFieldKey = "name"
    @AppStorage("playlistsList.sortOrder") private var sortOrderKey = "ascending"

    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// The playlist that has the song already, while asking whether to add it again.
    @State private var askedAbout: PlaylistSummary?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .alert("The song is already in this playlist", isPresented: Binding(
            get: { askedAbout != nil },
            set: { if !$0 { askedAbout = nil } }
        ), presenting: askedAbout) { playlist in
            Button("Add once again") { add(to: playlist) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && playlists.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if playlists.isEmpty {
            Text(loadError ?? String(localized: "No playlists found."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(displayedPlaylists) { playlist in
                    row(for: playlist)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
        }
    }

    private var displayedPlaylists: [PlaylistSummary] {
        PlaylistOrdering.sorted(playlists, field: sortFieldKey, ascending: sortOrderKey == "ascending")
    }

    private func row(for playlist: PlaylistSummary) -> some View {
        let contains = hasSong(playlist)
        return Button {
            if contains {
                askedAbout = playlist
            } else {
                add(to: playlist)
            }
        } label: {
            HStack(spacing: 12) {
                PlaylistRow(playlist: playlist, preparesPlaylistScreen: false, displayScale: displayScale)
                Spacer(minLength: 0)
                Image(systemName: contains ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(contains ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(contains ? .isSelected : [])
    }

    private func hasSong(_ playlist: PlaylistSummary) -> Bool {
        libraryCacheStatus.songIds(forPlaylist: playlist.id.raw)?.contains(song.id.raw) ?? false
    }

    private func add(to playlist: PlaylistSummary) {
        dismiss()
        onAdd(playlist)
    }

    /// The playlists, as `PlaylistsListView` gets them: what was cached at once, then what the
    /// server has if that's different.
    private func load() async {
        // What each playlist held, which the checkmarks come from, is read from disk once per run.
        await LibraryCacheStatus.shared.preload()
        guard SubsonicClient.shared.isConfigured else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        for await event in LibraryLoader.load(.allPlaylists(), shown: playlists) {
            switch event {
            case .cached(let cached):
                playlists = cached
                isLoading = false
            case .fresh(let fetched):
                loadError = nil
                playlists = fetched
                isLoading = false
            case .upToDate:
                loadError = nil
            case .failed(let error):
                if playlists.isEmpty { loadError = error.localizedDescription }
            }
        }
    }
}

enum PlaylistEditor {
    /// Adds `song` to the end of `playlist` on the server, and brings what's cached of the
    /// playlists up to date, so the sheet's checkmarks and the playlist screens show it.
    @MainActor
    static func add(_ song: Child, to playlist: PlaylistSummary) async throws {
        let client = SubsonicClient.shared
        try await client.updatePlaylist(playlistId: playlist.id.raw, songIdsToAdd: [song.id.raw])
        // Best-effort: the song is in the playlist either way.
        if let full = try? await client.getPlaylist(id: playlist.id.raw) {
            await LibraryCacheDatabase.shared.cachePlaylistSongs(full.entry ?? [], playlistId: playlist.id.raw)
        }
        if let playlists = try? await client.getPlaylists() {
            await LibraryCacheDatabase.shared.cacheAllPlaylists(playlists)
        }
    }
}
