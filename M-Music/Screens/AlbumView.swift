import SwiftUI

struct AlbumView: View {
    let album: AlbumID3
    var zoomNamespace: Namespace.ID? = nil

    private let client = SubsonicClient.shared
    @ObservedObject private var player = PlayerManager.shared

    /// Zoom transition for the "Other versions" / "More by artist" cards below — separate from
    /// the incoming `zoomNamespace` param, which only matches this view's own entry transition.
    @Namespace private var relatedAlbumZoomNamespace

    @State private var songs: [Child] = []
    @State private var albumCodec: String?
    @State private var isLoadingSongs = true
    @State private var loadError: String?

    @State private var otherVersions: [AlbumID3] = []
    @State private var moreByArtist: [AlbumID3] = []

    @State private var isStarred: Bool
    @State private var isDownloaded = false
    @State private var backgroundColor: Color

    init(album: AlbumID3, zoomNamespace: Namespace.ID? = nil) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        _isStarred = State(initialValue: album.isStarred)
        _backgroundColor = State(initialValue: Color(.systemBackground))
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
        // Only shows through the gap below the last row when content is shorter than the screen —
        // matches the related-albums section's own shade, since that's always the bottommost row.
        // `.basedOnSize` stops the list from bouncing/scrolling past that gap in the first place
        // when content already fills (or overflows) the screen, so this never has to paper over
        // an artificially-extended scroll area either.
        .background(relatedSectionBackground.ignoresSafeArea())
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
                moreByArtist = more
            }
        } catch {
            // Ignored — see doc comment above.
        }
    }

    /// A shade darker than the main artwork-derived background, so this section reads as visually
    /// distinct from the tracklist above it.
    private var relatedSectionBackground: Color {
        backgroundColor.darkened().darkened(by: 0.7)
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
            .padding(.vertical, 20)
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
            Divider()
                .overlay(.secondary.opacity(0.75))
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                trackRow(track)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playTrack(at: index)
                    }

                if index < songs.count - 1 {
                    Divider()
                        .overlay(.secondary.opacity(0.75))
                        .padding(.leading, trackTitleLeadingInset)
                }
            }
            Divider()
                .overlay(.secondary.opacity(0.75))
        }
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

    func trackRow(_ track: Child) -> some View {
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

            Button {} label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
                    .font(.system(size: 18))
            }
        }
    }

    func albumArtwork() -> some View {
        // Same URL AlbumCardView requests (original size, no `size` param), so this reuses the
        // image straight from ImageCache instead of re-fetching — the whole point being no lag
        // when this view opens.
        CachedAsyncImage(url: try? client.coverArtURL(forId: album.coverArt ?? album.id.raw)) { image in
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
