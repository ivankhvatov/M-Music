import SwiftUI

struct AlbumView: View {
    let album: Album
    var zoomNamespace: Namespace.ID? = nil

    @State private var backgroundColor: Color

    init(album: Album, zoomNamespace: Namespace.ID? = nil) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        _backgroundColor = State(initialValue: album.artwork.averageColor() ?? Color(.systemBackground))
    }

    var body: some View {
        if let zoomNamespace {
            navigationContent
                .navigationTransition(.zoom(sourceID: album.id, in: zoomNamespace))
        } else {
            navigationContent
        }
    }

    private var navigationContent: some View {
        NavigationStack {
            albumList
        }
        .preferredColorScheme(.dark)
    }

    var albumList: some View {
        List {
            VStack(alignment: .leading) {
                albumHeader()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            trackList()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            albumFooter()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 16, trailing: 16))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(backgroundColor.darkened())
        .toolbar {
            downloadButton
            moreButton
        }
        .tint(.primary)
    }

    /// Matches the leading edge of a track row's title: the row's own horizontal padding plus the track number's frame width and its spacing to the title.
    private let trackTitleLeadingInset: CGFloat = 4 + 20 + 12

    func trackList() -> some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(.secondary.opacity(0.75))
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 16)

                if index < album.tracks.count - 1 {
                    Divider()
                        .overlay(.secondary.opacity(0.75))
                        .padding(.leading, trackTitleLeadingInset)
                }
            }
            Divider()
                .overlay(.secondary.opacity(0.75))
        }
    }

    func trackSeparator() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.5))
            .frame(height: 0.5)
    }

    private var trackCountAndDuration: String {
        let trackCount = album.tracks.count
        let totalMinutes = Int(album.duration.components.seconds / 60)
        let songsText = String(localized: "\(trackCount) songs")
        let minutesText = String(localized: "\(totalMinutes) minutes")
        return "\(songsText), \(minutesText)"
    }

    func albumFooter() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trackCountAndDuration)

            if let label = album.label {
                Text("Ⓟ " + label)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func trackRow(_ track: Song) -> some View {
        HStack(spacing: 12) {
            Text(track.trackNumber.map(String.init) ?? "")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(minWidth: 20, alignment: .center)

            VStack (alignment: .leading) {
                Text(track.title)
                
                if (track.artist != album.artist) {
                    Text(track.artist.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if track.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

            Button {} label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
                    .font(.system(size: 18))
            }
        }
    }

    func albumArtwork() -> some View {
        album.artwork
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 270, maxHeight: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary, lineWidth: 0.15)
            )
            .shadow(color: .black.opacity(0.5), radius: 20)
    }
    
    func albumDetails() -> Text {
        var result: String = ""
        if (album.genre != nil) {
            result += album.genre!
        }
        if (album.releaseYear != nil) {
            if (result != "") {
                result += " • "
            }
            result += String(album.releaseYear!)
        }
        if (album.codec != nil) {
            if (result != "") {
                result += " • "
            }
            result += album.codec!
        }
        return Text(result)
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    func albumHeader() -> some View {
        HStack(alignment: .center) {
            Spacer()
            VStack(alignment: .center, spacing: 6) {
                albumArtwork()
                Text(
                    album.title + (album.edition != nil ? ("\n(" + album.edition! + ")") : "")
                )
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 15)
                Text(album.artist.joined(separator: ", "))
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

            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                    Text("Play")
                        .font(.system(size: 16))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(backgroundColor)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Color.white)
                .clipShape(Capsule())
            }

            Button {
                album.ToggleFavorite()
            } label: {
                Image(systemName: album.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }
    
    @ToolbarContentBuilder
        private var downloadButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if (album.isDownloaded == false) {
                        album.Download()
                    }
                } label: {
                    Image(systemName: album.isDownloaded ? "checkmark" : "arrow.down")
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
    AlbumView(
        album: TestModels.Diluvium
    )
}
