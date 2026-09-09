import SwiftUI

struct AlbumView: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    private let client = SubsonicClient.shared
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.displayScale) private var displayScale

    /// Zoom transition for the "Other versions" / "More by artist" cards below — separate from
    /// the incoming `zoomNamespace` param, which only matches this view's own entry transition.
    @Namespace private var relatedAlbumZoomNamespace

    @State private var songs: [Child] = []
    @State private var albumCodec: String?
    @State private var isLoadingSongs = true
    @State private var loadError: String?
    /// Per-track starred state, overriding `Child.isStarred` (`Child.starred` is server-decoded
    /// and immutable) once the user stars/unstars a track from its context menu. Keyed by track
    /// id; a track with no entry here just falls back to its own `isStarred`.
    @State private var trackStarOverrides: [String: Bool] = [:]

    @State private var otherVersions: [AlbumID3] = []
    @State private var moreByArtist: [AlbumID3] = []
    @State private var hasRelatedAlbums: Bool = false

    @State private var isStarred: Bool
    @State private var isDownloaded = false
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
    }

    var albumList: some View {
        List {
            VStack(alignment: .leading) {
                albumHeader()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.darkened())

            trackListSection()
                .listRowSeparator(.hidden)
                .listRowBackground(backgroundColor.darkened())

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

    private func loadSongs() async {
        do {
            let full = try await AlbumDetailsCache.shared.album(id: album.id.raw)
            await MainActor.run {
                songs = full.song ?? []
                albumCodec = full.codec
                isLoadingSongs = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoadingSongs = false
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
            let others = artist.album.filter { $0.id != album.id && $0.name == album.name }
            let more = artist.album.filter { $0.name != album.name }
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
                        NavigationLink(destination: AlbumView(album: relatedAlbum, zoomNamespace: relatedAlbumZoomNamespace)) {
                            AlbumCardView(album: relatedAlbum, zoomNamespace: relatedAlbumZoomNamespace)
                                .frame(width: 160)
                        }
                        .buttonStyle(.plain)
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
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
        } else {
            trackList()
        }
    }

    func trackList() -> some View {
        VStack(spacing: 0) {
            trackSeparator()
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                // A `Button` (rather than `.onTapGesture` on the row) so the trailing `Menu`'s own
                // taps take priority correctly — `.onTapGesture` on a container is a separate
                // gesture recognizer that can swallow taps meant for a nested interactive control
                // like `Menu`, whereas nesting an actual button-like control inside a `Button`'s
                // label is a configuration SwiftUI resolves hit-testing for correctly.
                Button {
                    playTrack(at: index)
                } label: {
                    trackRow(track, at: index)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Anchored to this row's own bottom edge rather than being a separate sibling in
                // the VStack — a sibling's position depends on the cumulative height of every row
                // above it, which made it fragile (and apparently still is even with an explicit,
                // fixed-size separator view) specifically once several rows in a row are taller
                // for showing a displayed artist name. Deriving the separator from this row's own
                // resolved geometry instead means it can't be affected by its neighbors.
                .overlay(alignment: .bottom) {
                        if index < songs.count - 1 {
                            trackSeparator()
                                .padding(.leading, trackTitleLeadingInset)
                        }
                    }
            }
            trackSeparator()
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

    private func playTrack(at index: Int) {
        player.play(queue: songs, startAt: index)
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

    func trackRow(_ track: Child, at index: Int) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        return HStack(spacing: 12) {
            Group {
                if isCurrent {
                    PlayingIndicator(isPlaying: player.isPlaying)
                } else {
                    Text(track.track.map(String.init) ?? "")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 20, alignment: .center)

            VStack(alignment: .leading) {
                Text(track.title)

                if let trackArtist = track.artist, trackArtist != album.artist {
                    Text(trackArtist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            trackMenu(track, at: index)
        }
    }

    private func trackMenu(_ track: Child, at index: Int) -> some View {
        let starred = isStarred(track)
        return Menu {
            // Not a `ControlGroup`/`.palette` row: that style is icon-only by design (no way to
            // opt back into showing titles), which would hide the label text these need.
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

    private func isStarred(_ track: Child) -> Bool {
        trackStarOverrides[track.id.raw] ?? track.isStarred
    }

    /// Stars/unstars a single track from its context menu — separate from `AlbumView`'s own
    /// `toggleStarred()` (the album-level star button), and from `PlayerManager.toggleStarred()`
    /// (only ever the currently-playing track), since this can act on any track in the list
    /// regardless of what's playing.
    private func toggleStarred(_ track: Child) {
        let newValue = !isStarred(track)
        trackStarOverrides[track.id.raw] = newValue
        Task {
            do {
                if newValue {
                    try await client.star(ids: [track.id.raw])
                } else {
                    try await client.unstar(ids: [track.id.raw])
                }
            } catch {
                await MainActor.run { trackStarOverrides[track.id.raw] = !newValue }
            }
        }
    }

    func albumArtwork() -> some View {
        // Same URL AlbumCardView requests (original size, no `size` param), so this reuses the
        // image straight from ImageCache instead of re-fetching — the whole point being no lag
        // when this view opens.
        CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .scaledToFit()
                .onAppear {
                    if let color = image.averageColor() {
                        backgroundColor = color
                    }
                }
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
            Button {} label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }

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

    @ToolbarContentBuilder
        private var downloadButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isDownloaded = true
                } label: {
                    Image(systemName: isDownloaded ? "checkmark" : "arrow.down")
                        .foregroundStyle(.primary)
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
