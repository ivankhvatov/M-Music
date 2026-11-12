import SwiftUI

/// The sheet behind an album's "Add to playlist": every playlist as a row like the ones of
/// `PlaylistsListView`, ending in a checkbox that says how much of the album that playlist has
/// already — none (`circle`), some (`checkmark.circle.dotted`) or all of it
/// (`checkmark.circle.fill`).
///
/// Tapping a playlist that has none of the album closes the sheet and adds all of its songs to the
/// end of the playlist. One that has some or all of it asks first, since adding would duplicate
/// songs; the answer decides which songs go in (see `Choice`).
///
/// Adding is the presenter's business (`onAdd`, handed the songs in album order) and goes on after
/// the sheet has gone.
struct AddAlbumToPlaylistSheet: View {
    /// The album's songs, in the album's order.
    let songs: [Child]
    let onAdd: (_ songs: [Child], _ playlist: PlaylistSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    /// Which playlists have which songs: the song ids each was last known to hold.
    @ObservedObject private var libraryCacheStatus = LibraryCacheStatus.shared
    /// The order the playlists screen is set to.
    @AppStorage("playlistsList.sortField") private var sortFieldKey = "name"
    @AppStorage("playlistsList.sortOrder") private var sortOrderKey = "ascending"

    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// The playlist that has some or all of the album already, while asking what to add.
    @State private var askedAbout: PlaylistSummary?

    /// How much of the album a playlist has.
    private enum Coverage {
        case absent, some, all

        var symbol: String {
            switch self {
            case .absent: "circle"
            case .some: "checkmark.circle.dotted"
            case .all: "checkmark.circle.fill"
            }
        }
    }

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
        .alert(alertTitle, isPresented: Binding(
            get: { askedAbout != nil },
            set: { if !$0 { askedAbout = nil } }
        ), presenting: askedAbout) { playlist in
            if coverage(of: playlist) == .all {
                Button("Add once again") { add(songs, to: playlist) }
            } else {
                Button("Add missing songs") { add(missingSongs(of: playlist), to: playlist) }
                Button("Add all songs") { add(songs, to: playlist) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var alertTitle: LocalizedStringKey {
        if let askedAbout, coverage(of: askedAbout) == .all {
            "All songs are already in the playlist"
        } else {
            "Some of the songs are already in the playlist"
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
        let coverage = coverage(of: playlist)
        return Button {
            if coverage == .absent {
                add(songs, to: playlist)
            } else {
                askedAbout = playlist
            }
        } label: {
            HStack(spacing: 12) {
                PlaylistRow(playlist: playlist, preparesPlaylistScreen: false, displayScale: displayScale)
                Spacer(minLength: 0)
                Image(systemName: coverage.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(coverage == .absent ? Color.secondary.opacity(0.5) : Color.appAccent)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(coverage == .absent ? [] : .isSelected)
    }

    private func coverage(of playlist: PlaylistSummary) -> Coverage {
        let missing = missingSongs(of: playlist).count
        if missing == songs.count { return .absent }
        return missing == 0 ? .all : .some
    }

    /// The album's songs the playlist doesn't have, in the album's order. A playlist whose songs
    /// aren't known has none of them as far as the sheet can tell.
    private func missingSongs(of playlist: PlaylistSummary) -> [Child] {
        guard let held = libraryCacheStatus.songIds(forPlaylist: playlist.id.raw), !held.isEmpty else {
            return songs
        }
        let heldIds = Set(held)
        return songs.filter { !heldIds.contains($0.id.raw) }
    }

    private func add(_ songsToAdd: [Child], to playlist: PlaylistSummary) {
        dismiss()
        onAdd(songsToAdd, playlist)
    }

    /// The playlists, as `PlaylistsListView` gets them: what was cached at once, then what the
    /// server has if that's different.
    private func load() async {
        // What each playlist held, which the checkboxes come from, is read from disk once per run.
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
