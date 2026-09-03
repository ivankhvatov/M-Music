import SwiftUI
import UIKit
import CoreImage

struct PlayerView: View {
    @State private var time: TimeInterval = 60.0
    @State private var total: TimeInterval = 226.0
    @State private var isPlaying: Bool = false

    @State private var isFavorite: Bool = false
    @State private var hasTimer: Bool = false
    @State private var showLyrics: Bool = false
    @State private var showQueue: Bool = false
    @State private var isMoreActive: Bool = false
    @State private var isSettingsActive: Bool = false

    @GestureState private var isScrubbing: Bool = false

    @State private var backgroundColor: Color = .gray

    private var bottomButtonSize : CGFloat = 22
    
    @State private var cover: Image = Image("cover_placeholder_4")
    @State private var title: String = "Drone Corpse Aviator"
    @State private var artist: String = "Archspire"

    var body: some View {
            ScrollView {
                // Контент скролла
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MainUI()
            }
            .background(backgroundColor)
            .onAppear {
                backgroundColor = averageColor(image: cover)
            }
        }

    func averageColor(image name: Image, darkenedBy factor: CGFloat = 0.55) -> Color {
        guard let uiImage = ImageRenderer(content: name).uiImage, let ciImage = CIImage(image: uiImage) else {
            return .gray
        }

        let parameters: [String: Any] = [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
        ]
        guard let outputImage = CIFilter(name: "CIAreaAverage", parameters: parameters)?.outputImage else {
            return .gray
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return Color(
            red: CGFloat(bitmap[0]) / 255 * factor,
            green: CGFloat(bitmap[1]) / 255 * factor,
            blue: CGFloat(bitmap[2]) / 255 * factor
        )
    }

    func MainUI() -> some View {
        VStack (spacing: 0) {
            Capsule()
                .fill(.gray.opacity(0.6))
                .frame(width: 65, height: 6, alignment: .center)
                .padding(.top, 7)
            Spacer()
            PlayerCover()
            Spacer()
            PlayerInfo()
            PlayerProgress()
            PlaybackRow()
            BottomButtons()
        }
        .padding(.horizontal, 25)
    }
    
    func PlayerCover() -> some View {
        cover
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 20)
            .padding(.vertical, 0)
    }
    
    func PlayerInfo() -> some View {
        HStack (spacing: 12) {
            VStack (alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2)
                    .foregroundStyle(.white)
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.transparentWhite)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }
    
    func PlayerProgress() -> some View {
        ZStack {
            ProgressTimers()
                .padding(.top, 45)
            ProgressBar()
        }
        .padding(.bottom, 30)
    }
    
    func ProgressBar() -> some View {
        GeometryReader { geo in
            let progress = total > 0 ? min(max(time / total, 0), 1) : 0
            let barHeight: CGFloat = isScrubbing ? 12 : 8

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: barHeight)
                Rectangle()
                    .fill(.white)
                    .frame(width: geo.size.width * progress, height: barHeight)
            }
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isScrubbing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isScrubbing) { _, isScrubbing, _ in
                        isScrubbing = true
                    }
                    .onChanged { value in
                        let newProgress = min(max(value.location.x / geo.size.width, 0), 1)
                        time = newProgress * total
                    }
            )
        }
        .frame(height: 44)
    }
    
    func ProgressTimers() -> some View {
        HStack {
            Text(formattedTime(time))
            Spacer()
            Text("-\(formattedTime(total - time))")
        }
        .font(.caption)
        .foregroundStyle(.transparentWhite)
        .monospacedDigit()
    }

    func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func PlaybackRow() -> some View {
        HStack{
            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 22))
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
                    .tint(.transparentWhite)
            }
            Spacer()
            PlaybackControlButtons()
            Spacer()
            Button {} label: {
                Image(systemName: "airplay.audio")
                    .font(.system(size: 22))
                    .contentShape(.rect)
                    .font(.system(size: bottomButtonSize))
                    .tint(.transparentWhite)
            }
        }
        .padding(.bottom, 50)
    }
    
    func PlaybackControlButtons() -> some View {
        HStack(spacing: 30) {
            Button {} label: {
                Image(systemName: "backward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 28))
            }
            Button {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                    isPlaying.toggle()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 60, height: 60)
                    .contentShape(.rect)
            }
            Button {} label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 28))
            }
        }
        .tint(.white)
    }
    
    func BottomButtons() -> some View {
        HStack (spacing: 32) {
            BottomButton("timer", isActive: $hasTimer)
            BottomButton("quote.bubble", isActive: $showLyrics)
            BottomButton("ellipsis", isActive: $isMoreActive)
            BottomButton("list.bullet", isActive: $showQueue)
            BottomButton("gearshape", isActive: $isSettingsActive)
        }
        .padding(.bottom, 5)
    }

    func BottomButton(_ systemName: String, isActive: Binding<Bool>) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isActive.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: bottomButtonSize))
                .foregroundStyle(isActive.wrappedValue ? backgroundColor : .white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.white)
                        .opacity(isActive.wrappedValue ? 1 : 0)
                )
                .contentShape(.rect)
        }
    }
}

#Preview {
    PlayerView()
}
