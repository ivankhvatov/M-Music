//
//  SongsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

private enum SongFilterOption: LocalizedStringKey, CaseIterable {
    case all = "All songs"
    case favoritesOnly = "Favorite only"

    /// Stable, non-localized identifier for persisting the selection — `rawValue` is a
    /// `LocalizedStringKey` and isn't suitable for storage.
    var storageKey: String {
        switch self {
        case .all: return "all"
        case .favoritesOnly: return "favoritesOnly"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .all
    }
}

private enum SongSortField: LocalizedStringKey, CaseIterable {
    case title = "Title"
    case artist = "Artist"
    case year = "Year"

    var storageKey: String {
        switch self {
        case .title: return "title"
        case .artist: return "artist"
        case .year: return "year"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .title
    }
}

private enum SongSortOrder: LocalizedStringKey, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    var storageKey: String {
        switch self {
        case .ascending: return "ascending"
        case .descending: return "descending"
        }
    }

    init(storageKey: String) {
        self = Self.allCases.first { $0.storageKey == storageKey } ?? .ascending
    }
}

struct SongsListView: View {
    private let client = SubsonicClient.shared
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var downloads = DownloadStore.shared

    @State private var searchText = ""

    @AppStorage("songsList.filterOption") private var filterOptionStorage = SongFilterOption.all.storageKey
    @AppStorage("songsList.sortField") private var sortFieldStorage = SongSortField.title.storageKey
    @AppStorage("songsList.sortOrder") private var sortOrderStorage = SongSortOrder.ascending.storageKey

    private var filterOption: Binding<SongFilterOption> {
        Binding(
            get: { SongFilterOption(storageKey: filterOptionStorage) },
            set: { filterOptionStorage = $0.storageKey }
        )
    }
    private var sortField: Binding<SongSortField> {
        Binding(
            get: { SongSortField(storageKey: sortFieldStorage) },
            set: { sortFieldStorage = $0.storageKey }
        )
    }
    private var sortOrder: Binding<SongSortOrder> {
        Binding(
            get: { SongSortOrder(storageKey: sortOrderStorage) },
            set: { sortOrderStorage = $0.storageKey }
        )
    }

    @State private var songs: [Child] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    /// Per-track starred state, overriding `Child.isStarred` (server-decoded and immutable) once
    /// the user stars/unstars a track from its context menu here.
    @State private var starOverrides: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                } else if displayedSongs.isEmpty {
                    Text("No songs found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(displayedSongs) { track in
                            Button {
                                play(track)
                            } label: {
                                songRow(track)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Songs")
            .searchable(text: $searchText, prompt: "Search songs")
            .toolbar {
                filterButton
                sortButton
            }
            .onAppear {
                refresh()
            }
            // Toggling the current track's star (from here or from the mini/full player) only
            // updates `player.isCurrentTrackStarred` — `isStarred(_:)` reads that directly for an
            // instant reflection while it's playing, but once the track stops being current that
            // source of truth goes away. Mirror every change into `starOverrides` as it happens,
            // so the last known state survives the switch to the next track (otherwise `isStarred`
            // falls back to the original, now-stale `track.isStarred` and the track appears to
            // re-star itself).
            .onChange(of: player.isCurrentTrackStarred) { _, newValue in
                if let id = player.currentTrack?.id.raw {
                    starOverrides[id] = newValue
                }
            }
        }
    }

    private func songRow(_ track: Child) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        return HStack(spacing: 12) {
            artwork(for: track, isCurrent: isCurrent)

            VStack(alignment: .leading) {
                Text(track.title)

                if let trackArtist = track.artist {
                    Text(trackArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            DownloadStatusIndicator(state: downloads.state(for: track.id.raw))

            songMenu(track)
        }
    }

    @ViewBuilder
    private func artwork(for track: Child, isCurrent: Bool) -> some View {
        ZStack {
            CachedAsyncImage(url: try? client.coverArtURL(forId: track.coverArt ?? track.albumId?.raw ?? track.id.raw)) { image in
                image
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            if isCurrent {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                PlayingIndicator(isPlaying: player.isPlaying, color: .white)
            }
        }
        .frame(width: 44, height: 44)
    }

    private func songMenu(_ track: Child) -> some View {
        let starred = isStarred(track)
        let downloadState = downloads.state(for: track.id.raw)
        return Menu {
            Button {
                toggleStarred(track)
            } label: {
                Label(
                    starred ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: starred ? "star.slash.fill" : "star.fill"
                )
            }

            Button {
                player.playNext(track)
            } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                player.addToQueue(track)
            } label: {
                Label("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            switch downloadState {
            case .completed:
                Button(role: .destructive) {
                    downloads.remove(songId: track.id.raw)
                } label: {
                    Label("Remove Download", systemImage: "checkmark.circle.fill")
                }
            case .queued, .downloading:
                Label("Downloading…", systemImage: "arrow.down.circle")
            default:
                Button {
                    downloads.download(track)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.primary)
                .font(.system(size: 18))
                .frame(height: 20)
                .contentShape(Rectangle())
        }
    }

    /// For the currently playing track, defers to `PlayerManager.isCurrentTrackStarred` instead
    /// of `starOverrides`/`track.isStarred` — it's `@Published`, so starring/unstarring from the
    /// mini or full player (which can happen while this list is on screen, since the player sits
    /// above it rather than replacing it) is reflected here the instant it happens, not just on
    /// the next fetch.
    private func isStarred(_ track: Child) -> Bool {
        if player.currentTrack?.id == track.id {
            return player.isCurrentTrackStarred
        }
        return starOverrides[track.id.raw] ?? track.isStarred
    }

    private func toggleStarred(_ track: Child) {
        // Route through PlayerManager rather than maintaining a separate override, so the two
        // stay in sync and don't race each other with independent star/unstar network calls.
        if player.currentTrack?.id == track.id {
            player.toggleStarred()
            return
        }
        let newValue = !isStarred(track)
        starOverrides[track.id.raw] = newValue
        Task {
            do {
                if newValue {
                    try await client.star(ids: [track.id.raw])
                } else {
                    try await client.unstar(ids: [track.id.raw])
                }
            } catch {
                await MainActor.run { starOverrides[track.id.raw] = !newValue }
            }
        }
    }

    private func play(_ track: Child) {
        guard let index = displayedSongs.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(queue: displayedSongs, startAt: index)
    }

    private var displayedSongs: [Child] {
        var result = songs

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { isStarred($0) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        result.sort { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField.wrappedValue {
            case .title:
                comparison = lhs.title.sortKey.localizedStandardCompare(rhs.title.sortKey)
            case .artist:
                comparison = (lhs.artist ?? "").sortKey.localizedStandardCompare((rhs.artist ?? "").sortKey)
            case .year:
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                comparison = lhsYear == rhsYear ? .orderedSame : (lhsYear < rhsYear ? .orderedAscending : .orderedDescending)
            }
            return sortOrder.wrappedValue == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        return result
    }

    private func refresh() {
        guard client.isConfigured else {
            songs = []
            hasLoadedOnce = false
            return
        }
        guard !isLoading else { return }

        if !hasLoadedOnce {
            isLoading = true
        }
        Task {
            do {
                let fetched = try await fetchAllSongs()
                await MainActor.run {
                    songs = fetched
                    loadError = nil
                    isLoading = false
                    hasLoadedOnce = true
                }
            } catch {
                await MainActor.run {
                    if !hasLoadedOnce {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }

    /// There's no dedicated "list every song" endpoint in the Subsonic API — an empty `search3`
    /// query matches every track, which is the standard way clients browse the full library.
    private func fetchAllSongs() async throws -> [Child] {
        var result: [Child] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = try await client.search3(
                query: "", artistCount: 0, albumCount: 0, songCount: pageSize, songOffset: offset
            ).song ?? []
            result.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return result
    }

    @ToolbarContentBuilder
    private var filterButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Filter", selection: filterOption) {
                    ForEach(SongFilterOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.horizontal.3.decrease")
                    .foregroundStyle(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var sortButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: sortField) {
                    ForEach(SongSortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.inline)

                Picker("Order", selection: sortOrder) {
                    ForEach(SongSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    SongsListView()
}
