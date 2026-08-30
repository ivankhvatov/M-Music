import SwiftUI

struct MiniPlayerView: View {
    var body: some View {
        HStack (spacing: 11) {
            PlayerCover(.init(width: 36, height: 36), .init(6))
            PlayerInfo()
            Spacer(minLength: 0)
            Button {
                
            } label: {
                Image(systemName: "play.fill")
                    .contentShape(.rect)
                    .tint(.mainText)
            }
            .padding(.trailing, 10)
            Button {
                
            } label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .tint(.mainText)
            }
        }
        .padding(.horizontal, 17)
    }
    
    func PlayerCover(_ size: CGSize, _ radius: CGFloat) -> some View {
        Image("cover_placeholder")
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
    
    func PlayerInfo() -> some View {
        HStack (spacing: 12) {
            VStack (alignment: .leading, spacing: 4) {
                Text("Track")
                    .font(.callout)
                Text("Artist")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .lineLimit(1)
        }
    }
}

#Preview {
    MiniPlayerView()
}
