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
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.displayScale) private var displayScale

    @State private var searchText = ""

    @AppStorage("songsList.filterOption") private var filterOptionStorage = SongFilterOption.all.storageKey
    @AppStorage("songsList.sortField") private var sortFieldStorage = SongSortField.title.storageKey
    @AppStorage("songsList.sortOrder") private var sortOrderStorage = SongSortOrder.ascending.storageKey
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInLists) private var showUnavailableInLists = true

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
    /// `songs` sorted by the current field/order, recomputed only when `songs` or the sort
    /// changes — see `AlbumsListView.sortedAlbums`. For a library of thousands of tracks the sort
    /// is the expensive part; filtering (search, favorites, offline) preserves this order.
    @State private var sortedSongs: [Child] = []

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
                            .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .refreshable { await performRefresh(force: true) }
            .navigationTitle("Songs")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                filterButton
                sortButton
            }
            .task { await refresh() }
            .onChange(of: songs) { updateSortedSongs() }
            .onChange(of: searchText) { updateDisplayedSongs() }
            .onChange(of: filterOptionStorage) { updateDisplayedSongs() }
            .onChange(of: sortFieldStorage) { updateSortedSongs() }
            .onChange(of: sortOrderStorage) { updateSortedSongs() }
            .onChange(of: starStore.overrides) { if filterOption.wrappedValue == .favoritesOnly { updateDisplayedSongs() } }
            .onChange(of: showUnavailableInLists) { updateDisplayedSongs() }
            .onChange(of: networkMonitor.isOnline) { updateDisplayedSongs() }
            .onChange(of: downloads.revision) { if offlineFilterActive { updateDisplayedSongs() } }
        }
    }

    /// `displayedSongs` itself while online; offline, only the ones actually downloaded — so
    /// playing forward from a tapped (necessarily downloaded, since its row is disabled
    /// otherwise) track never queues up something that's about to fail to stream with no network.
    private var playableSongs: [Child] {
        networkMonitor.isOnline ? displayedSongs : displayedSongs.filter { downloads.isDownloaded($0.id.raw) }
    }

    private func play(_ track: Child) {
        let queue = playableSongs
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(queue: queue, startAt: index)
    }

    private func updateSortedSongs() {
        // Read once, outside the sort: each read builds a `Binding` and scans `allCases`.
        let ascending = sortOrder.wrappedValue == .ascending
        switch sortField.wrappedValue {
        case .title:
            sortedSongs = songs.sortedByLocalizedKey(ascending: ascending) { $0.title.sortKey }
        case .artist:
            sortedSongs = songs.sortedByLocalizedKey(ascending: ascending) { ($0.artist ?? "").sortKey }
        case .year:
            sortedSongs = songs.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                return ascending ? lhsYear < rhsYear : lhsYear > rhsYear
            }
        }
        updateDisplayedSongs()
    }

    /// See `AlbumsListView.offlineFilterActive`.
    private var offlineFilterActive: Bool {
        !networkMonitor.isOnline && !showUnavailableInLists
    }

    /// Filters the already-sorted `sortedSongs`, preserving its order.
    private func updateDisplayedSongs() {
        var result = sortedSongs

        if filterOption.wrappedValue == .favoritesOnly {
            result = result.filter { starStore.isStarred($0) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        if offlineFilterActive {
            result = result.filter { downloads.isDownloaded($0.id.raw) }
        }

        displayedSongs = result
    }

    /// Stale-while-revalidate: shows cached songs immediately (no spinner) if any are cached,
    /// then revalidates against the server and only touches the displayed list if the fresh
    /// result actually differs from what's already shown. Loading, the "did anything change?"
    /// check and the cache write all happen in `LibraryLoader`, off the main actor; this only
    /// applies what it reports. Runs from `.task`, so leaving the screen cancels it.
    private func refresh() async {
        guard client.isConfigured else {
            songs = []
            hasLoadedOnce = false
            return
        }
        // Only the very first load shows the spinner (and thus swaps out the list) — a quiet
        // reappearance must never briefly tear down the list's identity, or it resets scroll
        // position.
        if !hasLoadedOnce {
            isLoading = true
        }
        await performRefresh()
    }

    /// `force` skips the "has the server library changed?" check, for pull-to-refresh.
    private func performRefresh(force: Bool = false) async {
        guard client.isConfigured else { return }
        defer { isLoading = false }
        for await event in LibraryLoader.load(.allSongs(), shown: songs, force: force) {
            switch event {
            case .cached(let cached):
                songs = cached
                hasLoadedOnce = true
                isLoading = false
            case .fresh(let fetched):
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
                songs = fetched
            case .upToDate:
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                isLoading = false
                if songs.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
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
    /// Shows a drag-handle glyph in place of the download status and song menu — for the player's
    /// queue list, where those don't apply.
    let showsReorderHandle: Bool
    /// Forwards the reorder handle's drag gesture up to `PlayerQueueList`, which owns the
    /// dragged-row state and does the actual reordering.
    var onReorderDragChanged: ((PanGesture.Value) -> Void)?
    var onReorderDragEnded: (() -> Void)?

    private let client = SubsonicClient.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// Resolved once, in `init` — `coverArtURL` signs every call with a fresh random token, so
    /// recomputing it inline in `body` would hand `CachedAsyncImage` a "new" URL (and restart its
    /// load task) on every one of this row's re-renders, even though it's the same image every
    /// time. Mirrors the fix already applied to `AlbumView`'s artwork URL.
    @State private var artworkURL: URL?

    /// Caches a signed artwork URL by art id + pixel size, so repeatedly constructing a `SongRow`
    /// for the *same* track — e.g. the queue list's dragged row, reconstructed on every gesture
    /// callback while it tracks the finger — doesn't redo `coverArtURL`'s signing (a random salt
    /// plus an MD5 hash, hex-formatted byte by byte) each time purely to throw the result away
    /// via `@State`'s first-appearance-only semantics. Subsonic's salt+token scheme has no
    /// server-side single-use/expiry tracking — the server just recomputes the hash from the
    /// salt and password — so a cached URL keeps working for as long as the credentials do; this
    /// is safe to reuse indefinitely within a session, not just across one render pass. Plain
    /// `static var`, not an actor: `SongRow.init` only ever runs on the main thread (SwiftUI
    /// constructs views on the main actor), so there's nothing concurrent to guard against.
    private static var artworkURLCache: [String: URL] = [:]

    init(
        track: Child,
        rowArtworkSize: CGFloat,
        displayScale: CGFloat,
        showsReorderHandle: Bool = false,
        onReorderDragChanged: ((PanGesture.Value) -> Void)? = nil,
        onReorderDragEnded: (() -> Void)? = nil
    ) {
        self.track = track
        self.rowArtworkSize = rowArtworkSize
        self.displayScale = displayScale
        self.showsReorderHandle = showsReorderHandle
        self.onReorderDragChanged = onReorderDragChanged
        self.onReorderDragEnded = onReorderDragEnded
        let artId = track.coverArt ?? track.albumId?.raw ?? track.id.raw
        let pixelSize = Int(rowArtworkSize * displayScale)
        let cacheKey = "\(artId)#\(pixelSize)"
        if let cached = Self.artworkURLCache[cacheKey] {
            _artworkURL = State(initialValue: cached)
        } else {
            let resolved = try? SubsonicClient.shared.coverArtURL(forId: artId, size: pixelSize)
            if let resolved { Self.artworkURLCache[cacheKey] = resolved }
            _artworkURL = State(initialValue: resolved)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                artwork

                VStack(alignment: .leading) {
                    Text(track.title)
                        .font(.callout)

                    if let trackArtist = track.artist {
                        Text(trackArtist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // The queue's compact rows (the ones with the handle) keep to one line each.
                .lineLimit(showsReorderHandle ? 1 : nil)
            }
            // Dims just the artwork/title — not the indicator or menu below, which should stay
            // fully legible/actionable (e.g. still show a download in progress, or let the user
            // start one) regardless of this track's current download state. Nothing is ever
            // "unavailable" while online — everything can still stream.
            .dimmedIfUnavailable(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw))

            Spacer()

            if showsReorderHandle {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 22))
                    // No fixed width: a wider tap-target box here would leave empty space past
                    // the glyph before the row's trailing edge, where the download symbol would
                    // otherwise sit — the glyph should hug the edge instead.
                    .frame(height: 20)
                    .contentShape(.rect)
                    .gesture(
                        PanGesture(
                            onChange: { onReorderDragChanged?($0) },
                            onEnd: { _ in onReorderDragEnded?() },
                            priorityName: PanGesture.reorderHandleTag
                        )
                    )
            } else {
                SongTrailingActions(track: track)
            }
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
}

/// The download status indicator + song menu shown at the trailing edge of a full (non-reorder-
/// handle) `SongRow`. Split out so its `starStore` subscription — used only by the menu's
/// favorite toggle — and this view's own `downloads` subscription don't exist at all when
/// `SongRow` is in reorder-handle mode, where it's reconstructed on every drag gesture callback
/// for the actively-dragged row. Mirrors `SongNowPlayingOverlay`: a leaf view scoped to exactly
/// what it reads.
private struct SongTrailingActions: View {
    let track: Child

    private let player = PlayerManager.shared
    @ObservedObject private var starStore = StarStore.shared
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        DownloadStatusIndicator(state: downloads.state(for: track.id.raw))
        songMenu
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
