import SwiftUI

struct AlbumView: View {
    let album: Album

    @State private var backgroundColor: Color = Color(.systemBackground)

    var body: some View {
        NavigationStack {
            albumList
        }
        .preferredColorScheme(.dark)
        .task {
            if let color = await album.artwork.averageColor() {
                withAnimation {
                    backgroundColor = color.darkened()
                }
            }
        }
    }

    var albumList: some View {
        List {
            VStack(alignment: .leading) {
                albumHeader()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                ForEach(album.tracks, id: \.id) { track in
                    trackRow(track)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(backgroundColor)
        .toolbar {
            moreButton
        }
    }

    func trackRow(_ track: Song) -> some View {
        HStack(spacing: 12) {
            Text(track.trackNumber.map(String.init) ?? "")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(minWidth: 20, alignment: .leading)

            Text(track.title)
                .lineLimit(1)

            Spacer()

            if track.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
            }

            Button {} label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
    }

    func albumArtwork() -> some View {
        album.artwork
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 270, maxHeight: 270)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 50)
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
        if (album.edition != nil) {
            if (result != "") {
                result += " • "
            }
            result += album.edition!
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
                Text(album.title)
                    .font(.system(size: 24))
                    .padding(.top, 15)
                Text(album.artist)
                    .font(.title3)
                albumDetails()
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
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
        album: TestModels.album
    )
}
