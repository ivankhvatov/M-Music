import SwiftUI

struct AlbumView: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    private let client = SubsonicClient.shared
    /// Not `@ObservedObject`: this view only ever calls a method on it (`playTrack(at:)` below),
    /// never reads a `@Published` property in `body` — observing it would re-run this entire
    /// view's body (recomputing the whole tracklist) on every playback tick. `TrackRow` observes
    /// it instead, scoped to just the currently-visible rows.
    private let player = PlayerManager.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.displayScale) private var displayScale

    /// Zoom transition for the "Other versions" / "More by artist" cards below — separate from
    /// the incoming `zoomNamespace` param, which only matches this view's own entry transition.
    @Namespace private var relatedAlbumZoomNamespace

    @State private var songs: [Child] = []
    @State private var albumCodec: String?
    @State private var isLoadingSongs = true
    @State private var loadError: String?
    /// The full fetched/cached album detail `songs`/`albumCodec` were last derived from — kept
    /// only so `loadSongs()` can diff a fresh fetch against it (fields beyond `.song`, e.g. play
    /// count/rating, are captured too), not surfaced anywhere else.
    @State private var currentAlbumDetail: AlbumWithSongsID3?

    @State private var otherVersions: [AlbumID3] = []
    @State private var moreByArtist: [AlbumID3] = []
    @State private var hasRelatedAlbums: Bool = false

    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false
    @AppStorage(OfflineModeSettings.Keys.showUnavailableInAlbums) private var showUnavailableInAlbums = true

    @State private var isStarred: Bool
    @State private var backgroundColor: Color

    /// Computed once, in `init` (not inline in `albumArtwork()`, and not deferred to a `.task`)
    /// and cached — `coverArtURL` signs every call with a fresh random token, and this view
    /// re-renders on every `PlayerManager` tick (it's `@ObservedObject`), so recomputing inline
    /// would hand `CachedAsyncImage` a "new" URL on every body evaluation and re-run its load
    /// task needlessly. Computing it synchronously in `init` rather than in a `.task` matters
    /// too: `CachedAsyncImage` does a synchronous in-memory cache check at `init`, so having a
    /// real URL ready for its very first render is what lets an already-cached cover (e.g. from
    /// `AlbumCardView`, which requests this same URL) appear immediately instead of flashing the
    /// placeholder for a frame while an async task first goes and computes the URL.
    @State private var artworkURL: URL?

    /// How far the list is scrolled from its top edge — drives a smooth blend between the artwork
    /// color and the related-albums section's darker shade as the top of the list nears the
    /// translucent nav bar (see `listBackground`).
    @State private var scrollEdgeOffsets = ScrollEdgeOffsets()
    @State private var showingRemoveDownloadConfirmation = false
    @State private var pendingRelatedAlbum: AlbumID3?

    init(album: AlbumID3, zoomNamespace: Namespace.ID? = nil) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        _isStarred = State(initialValue: album.isStarred)
        _backgroundColor = State(initialValue: Color(.systemBackground))
        _artworkURL = State(initialValue: try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw))
    }

    var body: some View {
        Group {
            if let zoomNamespace {
                albumList
                    .navigationTransition(.zoom(sourceID: album.id, in: zoomNamespace))
            } else {
                albumList
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadSongs()
        }
        .task {
            await loadRelatedAlbums()
        }
        .navigationDestination(item: $pendingRelatedAlbum) { relatedAlbum in
            AlbumView(album: relatedAlbum, zoomNamespace: relatedAlbumZoomNamespace)
        }
    }

    var albumList: some View {
        List {
            VStack(alignment: .leading) {
                albumHeader()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.darkened())

            trackListSection()

            albumFooter()
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 16, trailing: 16))

            relatedAlbumsSection()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(relatedSectionBackground)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(
            hasRelatedAlbums ? listBackground.ignoresSafeArea() : backgroundColor.darkened().ignoresSafeArea()
        )
        .onScrollGeometryChange(for: ScrollEdgeOffsets.self) { geometry in
            ScrollEdgeOffsets(fromTop: geometry.contentOffset.y)
        } action: { _, newValue in
            scrollEdgeOffsets = newValue
        }
        .scrollBounceBehavior(.basedOnSize)
        .toolbar {
            downloadButton
            moreButton
        }
        .tint(.primary)
    }

    /// Stale-while-revalidate: shows this album's cached songs immediately (no spinner) if
    /// cached, then revalidates against the server in the background and only touches the
    /// displayed songs/codec (and re-caches) if the fresh result actually differs from what's
    /// shown — compared via the full `AlbumWithSongsID3`, not just its `.song` array, so a
    /// change to any cached field (not only the track list) still triggers an update.
    private func loadSongs() async {
        if currentAlbumDetail == nil, let cached = await LibraryCacheDatabase.shared.cachedAlbumSongs(albumId: album.id.raw) {
            await MainActor.run {
                currentAlbumDetail = cached
                songs = cached.song ?? []
                albumCodec = cached.codec
                isLoadingSongs = false
            }
        }

        do {
            let full = try await client.getAlbum(id: album.id.raw)
            let changed = full != currentAlbumDetail
            await MainActor.run {
                isLoadingSongs = false
                loadError = nil
                if changed {
                    currentAlbumDetail = full
                    songs = full.song ?? []
                    albumCodec = full.codec
                }
            }
            if changed {
                await LibraryCacheDatabase.shared.cacheAlbumSongs(full, albumId: album.id.raw)
            }
        } catch {
            // Offline, or the request otherwise failed — keep showing whatever's already on
            // screen (cache, or an earlier successful fetch); only surface an error if there's
            // truly nothing to show.
            await MainActor.run {
                isLoadingSongs = false
                if songs.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    /// Fetches the rest of this album's artist catalog and splits it into "other versions" of
    /// this same album (same title, different `version` tag) and everything else by that artist.
    /// Supplementary content — fails silently rather than surfacing an error for it.
    private func loadRelatedAlbums() async {
        guard let artistId = album.artistId?.raw else { return }
        do {
            let artist = try await client.getArtist(id: artistId)
            let albumName = album.name.lowercased()
            let others = artist.album.filter { $0.id != album.id && $0.name.lowercased() == albumName }
            var more = artist.album.filter { $0.name.lowercased() != albumName }
            if groupReleaseVersionsEnabled {
                more = more.groupedByPreferredVersion()
            }
            await MainActor.run {
                otherVersions = others
                moreByArtist = more.reversed()
            }
            hasRelatedAlbums = !others.isEmpty || !more.isEmpty
        } catch {
            // Ignored — see doc comment above.
        }
    }

    /// A shade darker than the main artwork-derived background, so this section reads as visually
    /// distinct from the tracklist above it.
    private var relatedSectionBackground: Color {
        backgroundColor.darkened().darkened(by: 0.8)
    }

    /// Blends from the artwork color to `relatedSectionBackground` as the list scrolls within
    /// 50pt of its top edge, so the area behind the translucent nav bar transitions smoothly
    /// alongside the scroll instead of snapping between the two colors.
    private var listBackground: Color {
        let fraction = min(max(scrollEdgeOffsets.fromTop / 50, 0), 1)
        return backgroundColor.darkened().interpolated(to: relatedSectionBackground, fraction: fraction)
    }

    @ViewBuilder
    private func relatedAlbumsSection() -> some View {
        if !otherVersions.isEmpty || !moreByArtist.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                if !otherVersions.isEmpty {
                    albumCarousel(title: String(localized: "Other versions"), albums: otherVersions)
                }
                if !moreByArtist.isEmpty {
                    albumCarousel(title: String(localized: "More by \(album.artist ?? "")"), albums: moreByArtist)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func albumCarousel(title: String, albums: [AlbumID3]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { relatedAlbum in
                        AlbumOpenButton(album: relatedAlbum, onOpen: { pendingRelatedAlbum = $0 }) {
                            AlbumCardView(album: relatedAlbum, zoomNamespace: relatedAlbumZoomNamespace, subtitle: .year)
                                .frame(width: 160)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Matches the leading edge of a track row's title: the row's own horizontal padding plus the track number's frame width and its spacing to the title.
    private let trackTitleLeadingInset: CGFloat = 4 + 20 + 12

    @ViewBuilder
    func trackListSection() -> some View {
        if isLoadingSongs {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())
        } else {
            trackList()
        }
    }

    // Not a single row holding a hand-stacked `VStack` of all songs (which is how this used to be
    // built): that shape ties every separator's vertical position to the cumulative height of
    // every row above it, and `TrackRow`'s text-driven heights routinely don't sum to a whole
    // number of physical pixels — the hairline then straddles two pixel rows and gets
    // antialiased into a fainter, uneven line, or effectively disappears, differently per row and
    // per rebuild (worse the taller a row got, e.g. one showing a displayed artist name). One real
    // `List` row per song sidesteps that: each row (and its separator overlay) is laid out from
    // its own height alone — see `PlaylistView.trackList()`, fixed the same way.
    /// `songs`, minus any "Show unavailable in albums" would hide (offline + not downloaded).
    /// Feeds `trackList()`'s `ForEach` directly — a hidden track must never be constructed at
    /// all, since `trackList()`'s row indices drive first/last-row layout and `playTrack(at:)`'s
    /// lookup. `playableSongs` (the actual playback queue) is unaffected by this setting — it
    /// only ever changes what's rendered, never what's playable.
    private var visibleSongs: [Child] {
        guard !networkMonitor.isOnline, !showUnavailableInAlbums else { return songs }
        return songs.filter { downloads.isDownloaded($0.id.raw) }
    }

    func trackList() -> some View {
        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, track in
            // A `Button` (rather than `.onTapGesture` on the row) so the trailing `Menu`'s own
            // taps take priority correctly — `.onTapGesture` on a container is a separate
            // gesture recognizer that can swallow taps meant for a nested interactive control
            // like `Menu`, whereas nesting an actual button-like control inside a `Button`'s
            // label is a configuration SwiftUI resolves hit-testing for correctly.
            Button {
                playTrack(at: index)
            } label: {
                TrackRow(track: track, albumArtist: album.artist)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw)))
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.darkened())
            // Every row's own vertical inset, rather than the system default a `List` row
            // otherwise picks up — that default only ever applied once to the whole tracklist
            // back when every track lived in one hand-stacked row; now that each track is its
            // own row, leaving it in place would stack it on top of this row's own `.padding
            // (.vertical, 16)` for every row after the first, making their top edge visibly
            // bigger than their bottom edge. Zeroing it here lets that 16pt padding be the only
            // thing controlling spacing, uniformly — except a bit of extra top/bottom inset on
            // the first/last row, to keep the action buttons and footer from sitting flush
            // against the tracklist's boundary rules. See `PlaylistView.trackList()`.
            .listRowInsets(EdgeInsets(
                top: index == 0 ? 12 : 0,
                leading: 16,
                bottom: index == visibleSongs.count - 1 ? 12 : 0,
                trailing: 16
            ))
            .overlay(alignment: .top) {
                if index == 0 {
                    trackSeparator()
                }
            }
            .overlay(alignment: .bottom) {
                if index < visibleSongs.count - 1 {
                    trackSeparator()
                        .padding(.leading, trackTitleLeadingInset)
                } else {
                    trackSeparator()
                }
            }
        }
    }

    /// A fixed-height rule rather than a plain `Divider()` — `Divider()` intermittently fails to
    /// render between two rows of different heights (e.g. a row with a displayed artist name
    /// next to one without), since its own height then has to be inferred rather than being
    /// explicit. The height is exactly one physical pixel — a fractional point value like 0.5
    /// lands on a non-integer pixel boundary at most scale factors, so antialiasing spreads it
    /// over a variable number of pixels depending on where it falls, making the line look
    /// thicker (and inconsistently so row to row) rather than a crisp hairline.
    private func trackSeparator() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.75))
            .frame(height: 1 / displayScale)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `songs` itself while online; offline, only the ones actually downloaded — so playing
    /// forward from a tapped (necessarily downloaded, since its row is disabled otherwise) track
    /// never queues up something that's about to fail to stream with no network.
    private var playableSongs: [Child] {
        networkMonitor.isOnline ? songs : songs.filter { downloads.isDownloaded($0.id.raw) }
    }

    private func playTrack(at index: Int) {
        let queue = playableSongs
        guard let startAt = queue.firstIndex(where: { $0.id == visibleSongs[index].id }) else { return }
        player.play(queue: queue, startAt: startAt)
    }

    private func shuffle() {
        let queue = playableSongs
        guard !queue.isEmpty else { return }
        player.play(queue: queue.shuffled(), startAt: 0)
    }

    private var trackCountAndDuration: String {
        let totalMinutes = album.duration / 60
        let songsText = String(localized: "\(album.songCount) songs")
        let minutesText = String(localized: "\(totalMinutes) minutes")
        return "\(songsText), \(minutesText)"
    }

    private var recordLabelText: String? {
        guard let recordLabels = album.recordLabels, !recordLabels.isEmpty else { return nil }
        return recordLabels.map(\.name).joined(separator: ", ")
    }

    func albumFooter() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trackCountAndDuration)

            if let recordLabelText {
                Text("Ⓟ " + recordLabelText)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func albumArtwork() -> some View {
        // Same URL AlbumCardView requests (original size, no `size` param), so this reuses the
        // image straight from ImageCache instead of re-fetching — the whole point being no lag
        // when this view opens.
        CachedAsyncImage(url: artworkURL, onLoad: { uiImage in
            Task.detached(priority: .userInitiated) {
                guard let color = uiImage.averageColor() else { return }
                await MainActor.run { backgroundColor = color }
            }
        }) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
        }
        .frame(maxWidth: 270, maxHeight: 270)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary, lineWidth: 0.15)
        )
        .shadow(color: .black.opacity(0.5), radius: 20)
    }

    func albumDetails() -> Text {
        let parts = [album.genre, album.year.map(String.init), albumCodec].compactMap { $0 }
        return Text(parts.joined(separator: " • "))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    func albumHeader() -> some View {
        HStack(alignment: .center) {
            Spacer()
            VStack(alignment: .center, spacing: 6) {
                albumArtwork()
                Text(
                    album.name + (album.version != nil ? ("\n(" + album.version! + ")") : "")
                )
                    .font(.system(size: 24, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 15)
                Text(album.artist ?? "Unknown Artist")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                albumDetails()
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                actionButtons()
                    .padding(.top, 16)
            }
            Spacer()
        }
    }

    func actionButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                shuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
            .disabled(songs.isEmpty)

            Button {
                playTrack(at: 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                    Text("Play")
                        .font(.system(size: 16))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(backgroundColor.darkened())
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .disabled(songs.isEmpty)

            Button {
                toggleStarred()
            } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleStarred() {
        let newValue = !isStarred
        isStarred = newValue
        Task {
            do {
                if newValue {
                    try await client.star(albumIds: [album.id.raw])
                } else {
                    try await client.unstar(albumIds: [album.id.raw])
                }
            } catch {
                await MainActor.run { isStarred = !newValue }
            }
        }
    }

    /// Whether every track in this album has been downloaded — the toolbar button downloads the
    /// whole album if not, or offers to remove it if so.
    private var isAlbumDownloaded: Bool {
        !songs.isEmpty && songs.allSatisfy { downloads.isDownloaded($0.id.raw) }
    }

    @ToolbarContentBuilder
        private var downloadButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if isAlbumDownloaded {
                        showingRemoveDownloadConfirmation = true
                    } else {
                        downloads.downloadAlbum(songs)
                    }
                } label: {
                    Image(systemName: isAlbumDownloaded ? "checkmark" : "arrow.down")
                        .foregroundStyle(.primary)
                }
                .disabled(songs.isEmpty)
                .confirmationDialog(
                    "Delete the album from this device?",
                    isPresented: $showingRemoveDownloadConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        downloads.removeAlbum(albumId: album.id.raw)
                    }
                }
            }
        }

    @ToolbarContentBuilder
        private var moreButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.primary)
                }
            }
        }
}

/// How far `AlbumView`'s list is scrolled from its top edge, in points — `0` means flush against
/// the top.
private struct ScrollEdgeOffsets: Equatable {
    var fromTop: CGFloat = 0
}

/// A single track row's content (playing indicator/track number, title/artist, download status,
/// overflow menu). A real `View` type — not just a function on `AlbumView` — so it can own its
/// own `@ObservedObject` subscriptions: a `PlayerManager` playback tick or a `DownloadStore`
/// progress update now only re-renders this one row instead of `AlbumView`'s entire body (and
/// the whole tracklist it builds).
/// The track-number-or-`PlayingIndicator` leading glyph. Isolated so only it re-renders on
/// `PlayerManager` playback ticks — `TrackRow` itself no longer observes `player`, so `trackMenu`
/// stays stable while open.
private struct TrackLeadingGlyph: View {
    let track: Child

    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        Group {
            if player.currentTrack?.id == track.id {
                PlayingIndicator(isPlaying: player.isPlaying)
            } else {
                Text(track.track.map(String.init) ?? "")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 20, alignment: .center)
    }
}

private struct TrackRow: View {
    let track: Child
    let albumArtist: String?

    /// Not `@ObservedObject`: `trackMenu` only ever calls a method on it (`playNext`/
    /// `addToQueue`), never reads a `@Published` property — observing it here would rebuild this
    /// row's `Menu` on every playback tick even while it's open, which is what caused the menu to
    /// visibly pulsate and occasionally drop taps. `TrackLeadingGlyph` observes it instead, scoped
    /// to just the leading glyph.
    private let player = PlayerManager.shared
    @ObservedObject private var starStore = StarStore.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                TrackLeadingGlyph(track: track)

                VStack(alignment: .leading) {
                    Text(track.title)

                    if let trackArtist = track.artist, trackArtist != albumArtist {
                        Text(trackArtist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Dims just the leading glyph/title — see `SongRow`'s identical comment for why the
            // indicator and menu stay at full opacity regardless. Nothing is ever "unavailable"
            // while online — everything can still stream.
            .dimmedIfUnavailable(networkMonitor.isOnline || downloads.isDownloaded(track.id.raw))

            Spacer()

            DownloadStatusIndicator(state: downloads.state(for: track.id.raw))

            trackMenu
        }
    }

    private var trackMenu: some View {
        let starred = starStore.isStarred(track)
        let downloadState = downloads.state(for: track.id.raw)
        return Menu {
            // Not a `ControlGroup`/`.palette` row: that style is icon-only by design (no way to
            // opt back into showing titles), which would hide the label text these need.
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
                // Enlarges the tappable area well past the glyph itself (Apple's ~44pt minimum
                // tap target) without changing how it looks.
                .frame(height: 20)
                .contentShape(Rectangle())
        }
    }
}

#Preview {
    NavigationStack {
        AlbumView(
            album: AlbumID3(
                id: "1", name: "Diluvium", artist: "Obscura", artistId: nil,
                coverArt: nil, songCount: 11, duration: 3243, playCount: nil, created: nil,
                starred: nil, year: 2018, genre: "Death Metal", userRating: nil
            )
        )
    }
}
