import SwiftUI

struct AlbumCardView: View {
    let album: Album
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            album.artwork
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Text(album.title)
                .font(.system(size: 15))
                .lineLimit(1)
            
            Text(album.artist)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }
}

// Preview Provider
#Preview {
    ZStack {
        
        AlbumCardView(
            album: TestModels.album
        )
    }
}
