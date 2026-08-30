import SwiftUI

struct PlayerView: View {
    @State private var time: TimeInterval = 60.0
    @State private var total: TimeInterval = 240.0
    @State private var isDragging: Bool = false
    @State private var isPlaying: Bool = false
    
    @State private var isFavorite: Bool = false
    @State private var hasTimer: Bool = false
    @State private var showLyrics: Bool = false
    @State private var showQueue: Bool = false
    
    private var bottomButtonSize : CGFloat = 25
    
    var body: some View {
            ScrollView {
                // Контент скролла
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MainUI()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.gray)
        }
        
    
    func MainUI() -> some View {
        VStack (spacing: 30) {
            Capsule()
                .fill(.primary.secondary)
                .frame(width: 65, height: 6, alignment: .center)
                .padding(.top, 7)
            PlayerCover()
            PlayerInfo()
            ProgressBar()
            PlaybackRow()
            BottomButtons()
        }
        .padding(.horizontal, 25)
    }
    
    func PlayerCover() -> some View {
        Image("cover_placeholder")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 50)
            .padding(.vertical, 20)
    }
    
    func PlayerInfo() -> some View {
        HStack (spacing: 12) {
            VStack (alignment: .leading, spacing: 4) {
                Text("Track")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text("Artist")
                    .font(.subheadline)
                    .foregroundStyle(.transparentWhite)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.top, 5)
    }
    
    func ProgressBar() -> some View {
        VStack(spacing: 8) {
            let barHeight: CGFloat = isDragging ? 12 : 8
            
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = total > 0 ? CGFloat(time / total) : 0
                let currentProgressWidth = max(0, min(width, width * progress))
                
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.2)
                    Color.white
                        .frame(width: currentProgressWidth)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            
                            let locationX = value.location.x
                            let percentage = max(0, min(1, locationX / width))
                            time = TimeInterval(percentage) * total
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: 12)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isDragging)
            ProgressTimers()
            
        }
        .padding(.vertical, 0)
    }

    func ProgressTimers() -> some View {
        HStack {
            Text(formatTime(time))
            Spacer()
            Text("-" + formatTime(total - time))
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.6))
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func PlaybackRow() -> some View {
        HStack{
            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
                    .tint(.transparentWhite)
            }
            Spacer()
            PlaybackControlButtons()
            Spacer()
            Button {} label: {
                Image(systemName: "airplay.audio")
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
                    .tint(.transparentWhite)
            }
        }
        .padding(.vertical, 10)
    }
    
    func PlaybackControlButtons() -> some View {
        HStack(spacing: 35) {
            Button {} label: {
                Image(systemName: "backward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 30))
            }
            Button {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                    isPlaying.toggle()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48))
                    .frame(width: 60, height: 60)
                    .contentShape(.rect)
            }
            Button {} label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 30))
            }
        }
        .tint(.white)
    }
    
    func BottomButtons() -> some View {
        HStack (spacing: 40) {
            Button {} label: {
                Image(systemName: hasTimer ? "timer.circle.fill" : "timer")
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
            }
            Button {
                showLyrics.toggle()
            } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
            }
            Button {} label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
            }
            Button {
                showQueue.toggle()
            } label: {
                Image(systemName: showQueue ? "list.bullet.rectangle.fill" : "list.bullet")
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
            }
            Button {} label: {
                Image(systemName: "gearshape")
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
            }
        }
        .padding(.top, 20)
        .tint(.white)
    }
}

#Preview {
    PlayerView()
}
