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
    /// playlist up to date, so the sheet's checkmarks and the playlist screens show it.
    @MainActor
    static func add(_ song: Child, to playlist: PlaylistSummary) async throws {
        try await add([song], to: playlist)
    }

    /// Adds `songs`, in that order, to the end of `playlist` on the server, and brings what's
    /// cached of the playlist up to date.
    ///
    /// The cache is written as soon as the server has taken the songs — its song list with them
    /// at the end, and the playlist's entry in the list of playlists with that many more songs —
    /// rather than only from what the server is asked for afterwards, which isn't certain to come
    /// (the connection can drop in between) and takes a moment. What the server then says
    /// replaces it.
    @MainActor
    static func add(_ songs: [Child], to playlist: PlaylistSummary) async throws {
        guard !songs.isEmpty else { return }
        let client = SubsonicClient.shared
        try await client.updatePlaylist(playlistId: playlist.id.raw, songIdsToAdd: songs.map(\.id.raw))
        await recordAdded(songs, to: playlist)

        // What the server has now, best-effort: the songs are in the playlist either way.
        let database = LibraryCacheDatabase.shared
        if let full = try? await client.getPlaylist(id: playlist.id.raw) {
            await database.cachePlaylistSongs(full.entry ?? [], playlistId: playlist.id.raw)
        }
        if let playlists = try? await client.getPlaylists() {
            await database.cacheAllPlaylists(playlists)
        }
    }

    /// What `remove(_:from:)` left the playlist with.
    struct Removal {
        /// The playlist's songs as the server has them now.
        let songs: [Child]
        /// Whether this call took the song out; `false` when it was already gone.
        let removed: Bool
    }

    /// Removes the one instance of `song` that `song.occurrence` names — the first, second, … time
    /// the song is in the playlist — from `playlist` on the server, and brings what's cached of the
    /// playlist up to date. A playlist can hold a song several times, and only that instance goes.
    ///
    /// The server removes by position, so the playlist is fetched first and the position found in
    /// what the server has *now*, not in the list on screen, which can be an older cached one.
    /// A song that's no longer there (removed from another device) is left alone.
    @MainActor
    static func remove(_ song: Child, from playlist: PlaylistSummary) async throws -> Removal {
        let client = SubsonicClient.shared
        let database = LibraryCacheDatabase.shared
        let current = try await client.getPlaylist(id: playlist.id.raw).entry ?? []

        var seen = 0
        var position: Int?
        for (index, entry) in current.enumerated() where entry.id == song.id {
            if seen == (song.occurrence ?? 0) {
                position = index
                break
            }
            seen += 1
        }
        guard let position else {
            await database.cachePlaylistSongs(current, playlistId: playlist.id.raw)
            return Removal(songs: current, removed: false)
        }

        try await client.updatePlaylist(playlistId: playlist.id.raw, songIndexesToRemove: [position])
        var remaining = current
        let removedSong = remaining.remove(at: position)
        await database.cachePlaylistSongs(remaining, playlistId: playlist.id.raw)
        await recordRemoved(removedSong, from: playlist)

        // What the server has now, best-effort: the song is out of the playlist either way.
        if let full = try? await client.getPlaylist(id: playlist.id.raw) {
            await database.cachePlaylistSongs(full.entry ?? [], playlistId: playlist.id.raw)
            remaining = full.entry ?? []
        }
        if let playlists = try? await client.getPlaylists() {
            await database.cacheAllPlaylists(playlists)
        }
        return Removal(songs: remaining, removed: true)
    }

    /// Takes the song off the playlist's cached entry in the list of playlists: one song fewer,
    /// that much shorter, and changed now. (Its cached song list is written by the caller.)
    static func recordRemoved(_ song: Child, from playlist: PlaylistSummary) async {
        let database = LibraryCacheDatabase.shared
        guard let playlists = await database.cachedAllPlaylists() else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        await database.cacheAllPlaylists(playlists.map { cached in
            guard cached.id == playlist.id else { return cached }
            return PlaylistSummary(
                id: cached.id, name: cached.name, comment: cached.comment, owner: cached.owner,
                public: cached.public, songCount: max(0, cached.songCount - 1),
                duration: max(0, cached.duration - (song.duration ?? 0)),
                created: cached.created, changed: now, coverArt: cached.coverArt
            )
        })
    }

    /// Puts the songs at the end of the playlist's cached song list, and counts them in the
    /// playlist's cached entry.
    static func recordAdded(_ songs: [Child], to playlist: PlaylistSummary) async {
        let database = LibraryCacheDatabase.shared
        // Only onto a song list that's cached whole; started from nothing it'd claim the playlist
        // holds these songs alone.
        if let cachedSongs = await database.cachedPlaylistSongs(playlistId: playlist.id.raw) {
            await database.cachePlaylistSongs(cachedSongs + songs, playlistId: playlist.id.raw)
        }
        if let playlists = await database.cachedAllPlaylists() {
            let now = ISO8601DateFormatter().string(from: Date())
            let addedDuration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
            await database.cacheAllPlaylists(playlists.map { cached in
                guard cached.id == playlist.id else { return cached }
                return PlaylistSummary(
                    id: cached.id, name: cached.name, comment: cached.comment, owner: cached.owner,
                    public: cached.public, songCount: cached.songCount + songs.count,
                    duration: cached.duration + addedDuration,
                    created: cached.created, changed: now, coverArt: cached.coverArt
                )
            })
        }
    }
}
