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
    /// Not `@ObservedObject`: this view only ever calls a method on it (`play(_:)` below), never
    /// reads a `@Published` property in `body` — observing it would re-run this view's full
    /// filter+sort over the entire library on every playback tick. `SongRow` observes it instead,
    /// scoped to just the currently-visible rows.
    private let player = PlayerManager.shared
    @ObservedObject private var starStore = StarStore.shared
    @Environment(\.displayScale) private var displayScale

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

    /// Cached result of filtering/sorting `songs`, recomputed only by `updateDisplayedSongs()`
    /// (see its call sites below) rather than on every `body` evaluation — this list can hold
    /// an entire library's worth of tracks, and re-filtering/re-sorting all of them on every
    /// access (there were 2-3 per `body` pass) was the dominant cause of this screen lagging.
    @State private var displayedSongs: [Child] = []

    /// Point size artwork renders at in a row — the server is asked to downscale to this times
    /// `displayScale` rather than sending full-size cover art for a 44x44 thumbnail.
    private let rowArtworkSize: CGFloat = 44

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
                                SongRow(track: track, rowArtworkSize: rowArtworkSize, displayScale: displayScale)
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
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                filterButton
                sortButton
            }
            .onAppear {
                refresh()
            }
            .onChange(of: songs) { updateDisplayedSongs() }
            .onChange(of: searchText) { updateDisplayedSongs() }
            .onChange(of: filterOptionStorage) { updateDisplayedSongs() }
            .onChange(of: sortFieldStorage) { updateDisplayedSongs() }
            .onChange(of: sortOrderStorage) { updateDisplayedSongs() }
            .onChange(of: starStore.overrides) { updateDisplayedSongs() }
        }
    }

    private func play(_ track: Child) {
        guard let index = displayedSongs.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(queue: displayedSongs, startAt: index)
    }

    private func updateDisplayedSongs() {
        var result = songs

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { starStore.isStarred($0) }
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

        displayedSongs = result
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

/// A single song row's content (artwork, title/artist, download status, overflow menu). A real
/// `View` type — not just a function on `SongsListView` — so it can own its own `@ObservedObject`
/// subscriptions: `List`/`ForEach` only materializes visible rows, so a `PlayerManager` playback
/// tick or a `DownloadStore` progress update now only re-renders the handful of on-screen rows
/// instead of `SongsListView`'s entire body (and the full-library resort that would trigger).
/// The artwork-darkening overlay + `PlayingIndicator` shown when this track is the one currently
/// playing. Isolated into its own leaf view so it alone re-renders on `PlayerManager` playback
/// ticks — `SongRow` itself no longer observes `player`, so its `Menu` stays stable while open.
private struct SongNowPlayingOverlay: View {
    let trackId: Child.ID
    let rowArtworkSize: CGFloat

    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        if player.currentTrack?.id == trackId {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.45))
                .frame(width: rowArtworkSize, height: rowArtworkSize)
            PlayingIndicator(isPlaying: player.isPlaying, color: .white)
        }
    }
}

struct SongRow: View {
    let track: Child
    let rowArtworkSize: CGFloat
    let displayScale: CGFloat

    private let client = SubsonicClient.shared
    /// Not `@ObservedObject`: `songMenu` only ever calls a method on it (`playNext`/
    /// `addToQueue`), never reads a `@Published` property — observing it here would rebuild this
    /// row's `Menu` on every playback tick even while it's open, which is what caused the menu to
    /// visibly pulsate and occasionally drop taps. `SongNowPlayingOverlay` observes it instead,
    /// scoped to just the artwork glyph.
    private let player = PlayerManager.shared
    @ObservedObject private var starStore = StarStore.shared
    @ObservedObject private var downloads = DownloadStore.shared

    /// Resolved once, in `init` — `coverArtURL` signs every call with a fresh random token, so
    /// recomputing it inline in `body` would hand `CachedAsyncImage` a "new" URL (and restart its
    /// load task) on every one of this row's re-renders, even though it's the same image every
    /// time. Mirrors the fix already applied to `AlbumView`'s artwork URL.
    @State private var artworkURL: URL?

    init(track: Child, rowArtworkSize: CGFloat, displayScale: CGFloat) {
        self.track = track
        self.rowArtworkSize = rowArtworkSize
        self.displayScale = displayScale
        let artId = track.coverArt ?? track.albumId?.raw ?? track.id.raw
        let pixelSize = Int(rowArtworkSize * displayScale)
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: artId, size: pixelSize))
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork

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

            songMenu
        }
    }

    private var artwork: some View {
        ZStack {
            // `.fit`, not `.fill` — a non-square cover keeps its own aspect ratio (its longer
            // side matching `rowArtworkSize`) instead of being cropped to fill a square, and the
            // rounded corners/outline below clip and trace its own resulting bounds rather than
            // the fixed square frame.
            CachedAsyncImage(url: artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary, lineWidth: 0.1)
                    )
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: rowArtworkSize, height: rowArtworkSize)

            SongNowPlayingOverlay(trackId: track.id, rowArtworkSize: rowArtworkSize)
        }
        .frame(width: rowArtworkSize, height: rowArtworkSize)
    }

    private var songMenu: some View {
        let starred = starStore.isStarred(track)
        let downloadState = downloads.state(for: track.id.raw)
        return Menu {
            Button {
                starStore.toggleStarred(track)
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
}

#Preview {
    SongsListView()
}
