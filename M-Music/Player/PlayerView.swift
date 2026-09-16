import SwiftUI
import UIKit
import CoreImage

struct PlayerView: View {
    @ObservedObject private var player = PlayerManager.shared

    @State private var hasTimer: Bool = false
    @State private var showLyrics: Bool = false
    @State private var showQueue: Bool = false
    @State private var isMoreActive: Bool = false
    @State private var isSettingsActive: Bool = false

    /// Live position while the user is dragging the scrubber; `nil` when not scrubbing, so the
    /// progress bar follows `player.currentTime` the rest of the time.
    @State private var scrubTime: TimeInterval?
    @GestureState private var isScrubbing: Bool = false

    @State private var backgroundColors: [Color] = [.gray, .gray]
    /// Bumped on every play/pause tap to restart `PlayPauseBurst`'s animation from scratch.
    @State private var playPauseBurstID = 0

    private var bottomButtonSize : CGFloat = 22

    private var displayTime: TimeInterval { scrubTime ?? player.currentTime }

    var body: some View {
            ScrollView {
                // Контент скролла
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MainUI()
            }
            .background(
                LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
            )
            .task(id: player.artworkURL) {
                await updateBackgroundColor()
            }
        }

    private func updateBackgroundColor() async {
        guard let url = player.artworkURL, let uiImage = await ImageCache.shared.load(url) else {
            backgroundColors = [.gray, .gray]
            return
        }
        let dominant = uiImage.dominantColors(count: 2).map { $0.darkened().darkened(by: 0.65) }
        switch dominant.count {
        case 2:
            backgroundColors = dominant
        case 1:
            backgroundColors = [dominant[0], dominant[0].darkened(by: 0.7)]
        default:
            backgroundColors = [.gray, .gray]
        }
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
            VStack {
                PlayerInfo()
                PlayerProgress()
                PlaybackRow()
                BottomButtons()
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
    }

    func PlayerCover() -> some View {
        CachedAsyncImage(url: player.artworkURL) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Rectangle()
                .fill(Color.white.opacity(0.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.7), radius: 20)
        .padding(.vertical, 0)
    }

    func PlayerInfo() -> some View {
        VStack (alignment: .leading, spacing: 4) {
            MarqueeText(text: player.currentTrack?.title ?? String(localized: "Not Playing"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            MarqueeText(text: player.currentTrack?.artist ?? "")
                .font(.subheadline)
                .foregroundStyle(.transparentWhite)
            if let audioInfoLine {
                Text(audioInfoLine)
                    .font(.caption)
                    .foregroundStyle(.transparentWhite.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// "Stream · FLAC · 24-bit/96 kHz" or "Downloaded · AAC · 256 kbps" — `nil` while the setting
    /// is off, nothing's playing, or the codec read (`PlayerManager.audioFormatInfo`) hasn't
    /// landed yet for the current track.
    private var audioInfoLine: String? {
        guard AudioInfoDisplaySettings.isEnabled, player.currentTrack != nil,
              let source = player.playbackSource, let format = player.audioFormatInfo
        else { return nil }
        var parts = [source.displayName, format.codec]
        if let bitDepth = format.bitDepth, let sampleRateHz = format.sampleRateHz {
            parts.append("\(bitDepth)-bit/\(Self.formattedSampleRate(sampleRateHz))")
        } else if let bitrateKbps = format.bitrateKbps {
            parts.append("\(bitrateKbps) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private static func formattedSampleRate(_ hz: Double) -> String {
        let khz = (hz / 1000 * 10).rounded() / 10
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
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
            let progress = player.duration > 0 ? min(max(displayTime / player.duration, 0), 1) : 0
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
                        scrubTime = newProgress * player.duration
                    }
                    .onEnded { _ in
                        if let scrubTime {
                            player.seek(to: scrubTime)
                        }
                        scrubTime = nil
                    }
            )
        }
        .frame(height: 44)
    }

    func ProgressTimers() -> some View {
        HStack {
            Text(formattedTime(displayTime))
            Spacer()
            Text("-\(formattedTime(player.duration - displayTime))")
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
                player.toggleStarred()
            } label: {
                Image(systemName: player.isCurrentTrackStarred ? "star.fill" : "star")
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
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 26))
            }
            Button {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
                    player.togglePlayPause()
                }
                playPauseBurstID += 1
            } label: {
                ZStack {
                    PlayPauseBurst(trigger: playPauseBurstID, endScale: 1.6)
                        .frame(width: 44, height: 44)
                    if player.isBuffering {
                        ProgressView()
                            .scaleEffect(1.4)
                    } else {
                        // No `.contentTransition(.symbolEffect(.replace))` here: its cross-fade
                        // briefly renders both the play triangle and the pause bars on top of each
                        // other. A plain instant swap plus the bounce pulse reads just as snappy
                        // without that overlap.
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 42))
                            .symbolEffect(.bounce, value: player.isPlaying)
                    }
                }
                .frame(width: 60, height: 60)
                .contentShape(.rect)
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .font(.system(size: 26))
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
            withAnimation(.spring(response: -0.1, dampingFraction: 0.75)) {
                isActive.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: bottomButtonSize))
                .foregroundStyle(isActive.wrappedValue ? backgroundColors.first ?? .gray : .white)
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
