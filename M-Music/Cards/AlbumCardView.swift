import SwiftUI

struct AlbumCardView: View {
    let album: Album
    var zoomNamespace: Namespace.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            Text(album.title + (album.edition != nil ? (" (" + album.edition! + ")") : ""))
                .font(.system(size: 15))
                .lineLimit(1)
            
            Text(album.artist.joined(separator: ", "))
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let image = album.artwork
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary, lineWidth: 0.15)
            )

        if let zoomNamespace {
            image.matchedTransitionSource(id: album.id, in: zoomNamespace)
        } else {
            image
        }
    }
}

// Preview Provider
#Preview {
    ZStack {
        
        AlbumCardView(
            album: TestModels.TooFastToDieJP
        )
    }
}
