//
//  SongsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import Combine
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
    /// None of these three is `@ObservedObject`: observing them re-ran this whole body — a
    /// `ForEach` over the entire library, identity-diffed on every pass — on every download
    /// progress tick, connectivity change or star. The screen reacts through the `.onReceive`s
    /// below, and the per-row `.disabled` lives in `SongListRow`, which only visible rows build.
    private let starStore = StarStore.shared
    private let downloads = DownloadStore.shared
    private let networkMonitor = NetworkMonitor.shared
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

    /// Cached result of filtering/sorting `songs`, recomputed only by `recompute()`
    /// (see its call sites below) rather than on every `body` evaluation — this list can hold
    /// an entire library's worth of tracks, and re-filtering/re-sorting all of them on every
    /// access (there were 2-3 per `body` pass) was the dominant cause of this screen lagging.
    @State private var displayedSongs: [Child] = []
    /// `songs` sorted by the current field/order, recomputed only when `songs` or the sort
    /// changes — see `AlbumsListView.sortedAlbums`. For a library of thousands of tracks the sort
    /// is the expensive part; filtering (search, favorites, offline) preserves this order.
    @State private var sortedSongs: [Child] = []
    /// Keeps the content hidden on first open until the first screenful's images are in memory.
    @State private var imageReadiness = ImageReadiness()
    /// Where each displayed row is, for warming the ones below a row that scrolls into view.
    @State private var rowPositions = RowPositions()
    /// Sorts/filters off the main actor — see `OffMainDeriver`.
    @State private var deriver = OffMainDeriver()

    /// Point size artwork renders at in a row — the server is asked to downscale to this times
    /// `displayScale` rather than sending full-size cover art for a 44x44 thumbnail.
    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.song

    var body: some View {
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
            } else if !imageReadiness.isReady {
                // Opened before the first screenful's images were ready: hold the content back
                // until they are (see `ImageReadiness`) rather than showing placeholders.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(displayedSongs) { track in
                        SongListRow(
                            track: track,
                            rowArtworkSize: rowArtworkSize,
                            displayScale: displayScale,
                            onPlay: { play(track) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .onAppear { warmAhead(after: track) }
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
        // A burst of keystrokes coalesces into one filter pass (the delay is inside `recompute`).
        .onChange(of: searchText) { recompute(debounced: true) }
        .onChange(of: filterOptionStorage) { recompute() }
        .onChange(of: sortFieldStorage) { markSortStale() }
        .onChange(of: sortOrderStorage) { markSortStale() }
        // `@Published` publishes from `willSet`, so a handler that re-read the store would see the
        // old value; stars are passed along from the payload, the rest are read after the fact.
        .onReceive(starStore.$overrides.dropFirst()) { overrides in
            if filterOption.wrappedValue == .favoritesOnly { recompute(starOverrides: overrides) }
        }
        .onChange(of: showUnavailableInLists) { recompute() }
        .onReceive(networkMonitor.$isOnline.removeDuplicates().dropFirst()) { _ in recompute() }
        .onReceive(downloads.$revision.dropFirst()) { _ in if offlineFilterActive { recompute() } }
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

    /// Everything `sorted`/`filtered` need, captured by value so they can run off the main actor.
    private struct DerivationSpec: Sendable {
        var field: SongSortField
        var ascending: Bool
        var favoritesOnly: Bool
        /// Only filled while the favorites filter is on (it's what `StarStore.isStarred` reads).
        var starOverrides: [String: Bool]
        var search: String
    }

    /// The items or the sort changed: the next derivation has to sort again.
    private func markSortStale() {
        deriver.sortStale = true
        recompute()
    }

    /// Re-derives `sortedSongs` (only if the items or sort changed) and `displayedSongs` off the
    /// main actor, and applies the newest result. Replaces the synchronous sort + filter over the
    /// whole library that used to run on the main actor on open, and again per search keystroke.
    private func recompute(debounced: Bool = false, starOverrides: [String: Bool]? = nil) {
        let items = songs
        let alreadySorted = sortedSongs
        let needsSort = deriver.sortStale
        let favoritesOnly = filterOption.wrappedValue == .favoritesOnly
        let spec = DerivationSpec(
            field: sortField.wrappedValue,
            ascending: sortOrder.wrappedValue == .ascending,
            favoritesOnly: favoritesOnly,
            starOverrides: favoritesOnly ? (starOverrides ?? starStore.overrides) : [:],
            search: searchText
        )
        deriver.run(delay: debounced ? .milliseconds(200) : nil, {
            let sorted = needsSort ? Self.sorted(items, spec) : alreadySorted
            return (sorted: sorted, displayed: Self.filtered(sorted, spec))
        }, apply: { result in
            deriver.sortStale = false
            sortedSongs = result.sorted
            // The offline filter reads main-actor stores, and is a cheap set lookup per item.
            displayedSongs = offlineFilterActive
                ? result.displayed.filter { downloads.isDownloaded($0.id.raw) }
                : result.displayed
            isLoading = false
            rememberFirstScreenful()
        })
    }

    private func artworkRequests(for songs: ArraySlice<Child>) -> [ArtworkRequest] {
        let scale = displayScale
        return songs.map { ArtworkRequest.songRow(ArtworkRequest.artworkId(of: $0), scale: scale) }
    }

    /// A row scrolled into view: warm the ones just below it, so a fast scroll finds them ready.
    private func warmAhead(after track: Child) {
        guard let index = rowPositions.position(of: track.id.raw),
              displayedSongs.indices.contains(index), displayedSongs[index].id == track.id else { return }
        let requests = artworkRequests(for: displayedSongs[(index + 1)...].prefix(ImageWarmer.scrollAheadCount))
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests) }
    }

    /// Tells `ImageWarmer` what this screen shows first, so its artwork is decoded ahead of the
    /// next visit (a search's results aren't what the screen normally opens with).
    private func rememberFirstScreenful() {
        rowPositions.update(ids: displayedSongs.map { $0.id.raw })
        let requests = artworkRequests(for: displayedSongs.prefix(ImageWarmer.manifestLimit))
        imageReadiness.require(requests)
        guard searchText.isEmpty else { return }
        Task { await ImageWarmer.shared.remember(.songs, requests) }
    }

    private nonisolated static func sorted(_ songs: [Child], _ spec: DerivationSpec) -> [Child] {
        switch spec.field {
        case .title:
            return songs.sortedByLocalizedKey(ascending: spec.ascending) { $0.title.sortKey }
        case .artist:
            return songs.sortedByLocalizedKey(ascending: spec.ascending) { ($0.artist ?? "").sortKey }
        case .year:
            return songs.sorted { lhs, rhs in
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                return spec.ascending ? lhsYear < rhsYear : lhsYear > rhsYear
            }
        }
    }

    /// Filters the already-sorted songs, preserving their order.
    private nonisolated static func filtered(_ sorted: [Child], _ spec: DerivationSpec) -> [Child] {
        var result = sorted
        if spec.favoritesOnly {
            result = result.filter { spec.starOverrides[$0.id.raw] ?? $0.isStarred }
        }
        if !spec.search.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(spec.search)
                    || ($0.artist?.localizedCaseInsensitiveContains(spec.search) ?? false)
            }
        }
        return result
    }

    /// See `AlbumsListView.offlineFilterActive`.
    private var offlineFilterActive: Bool {
        !networkMonitor.isOnline && !showUnavailableInLists
    }

    /// Stale-while-revalidate: shows cached songs immediately (no spinner) if any are cached,
    /// then revalidates against the server and only touches the displayed list if the fresh
    /// result actually differs from what's already shown. Loading, the "did anything change?"
    /// check and the cache write all happen in `LibraryLoader`, off the main actor; this only
    /// applies what it reports. Runs from `.task`, so leaving the screen cancels it.
    private func refresh() async {
        guard client.isConfigured else {
            songs = []
            sortedSongs = []
            displayedSongs = []
            deriver.cancel()
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
        // The spinner stays up until the first derivation lands, rather than flashing "No songs
        // found." while the (now off-main) sort is still running.
        defer { if !deriver.isPending { isLoading = false } }
        for await event in LibraryLoader.load(.allSongs(), shown: songs, force: force) {
            switch event {
            case .cached(let cached):
                songs = cached
                hasLoadedOnce = true
                markSortStale()
            case .fresh(let fetched):
                loadError = nil
                hasLoadedOnce = true
                songs = fetched
                markSortStale()
            case .upToDate:
                loadError = nil
                hasLoadedOnce = true
                if !deriver.isPending { isLoading = false }
            case .failed(let error):
                // Offline, or the request otherwise failed — keep showing whatever's already on
                // screen (cache, or an earlier successful fetch); only surface an error if
                // there's truly nothing to show.
                if !deriver.isPending { isLoading = false }
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

/// One tappable row of the songs list. Owns the observation of download and network state needed to
/// disable itself, so only the rows actually on screen react to it — the screen itself observes
/// neither (see `SongsListView`).
private struct SongListRow: View {
    let track: Child
    let rowArtworkSize: CGFloat
    let displayScale: CGFloat
    let onPlay: () -> Void

    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        Button(action: onPlay) {
            SongRow(track: track, rowArtworkSize: rowArtworkSize, displayScale: displayScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
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
    /// What tapping the row (not its handle) does, if it does anything: the queue list's rows play
    /// from there. Rows in the lists are tapped through their own button, and leave this unset.
    var onTap: (() -> Void)?
    /// Whether the artwork is darkened and gets the playing indicator while this is the track
    /// that's playing. Not in the queue list, whose rows are what's still to play.
    var showsPlayingIndicator = true

    private let client = SubsonicClient.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// Resolved once, in `init` — `coverArtURL` signs every call with a fresh random token, so
    /// recomputing it inline in `body` would hand `CachedAsyncImage` a "new" URL (and restart its
    /// load task) on every one of this row's re-renders, even though it's the same image every
    /// time. Mirrors the fix already applied to `AlbumView`'s artwork URL.
    @State private var artworkURL: URL?

    init(
        track: Child,
        rowArtworkSize: CGFloat,
        displayScale: CGFloat,
        showsReorderHandle: Bool = false,
        onReorderDragChanged: ((PanGesture.Value) -> Void)? = nil,
        onReorderDragEnded: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        showsPlayingIndicator: Bool = true
    ) {
        self.track = track
        self.rowArtworkSize = rowArtworkSize
        self.displayScale = displayScale
        self.showsReorderHandle = showsReorderHandle
        self.onReorderDragChanged = onReorderDragChanged
        self.onReorderDragEnded = onReorderDragEnded
        self.onTap = onTap
        self.showsPlayingIndicator = showsPlayingIndicator
        _artworkURL = State(initialValue: ArtworkRequest.songRow(ArtworkRequest.artworkId(of: track), scale: displayScale).url)
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
            .modifier(TapIfAvailable(
                isAvailable: networkMonitor.isOnline || downloads.isDownloaded(track.id.raw),
                action: onTap
            ))

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

            if showsPlayingIndicator {
                SongNowPlayingOverlay(trackId: track.id, rowArtworkSize: rowArtworkSize)
            }
        }
        .frame(width: rowArtworkSize, height: rowArtworkSize)
    }
}

/// Makes a row's content tappable when it has something to do — and, like the lists' rows, not
/// when the song can't be played (offline, and not downloaded). Leaves the content as it is
/// otherwise, so rows inside a button of their own keep getting their taps.
private struct TapIfAvailable: ViewModifier {
    let isAvailable: Bool
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(.rect)
                .onTapGesture { if isAvailable { action() } }
        } else {
            content
        }
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
    NavigationStack {
        SongsListView()
    }
}
