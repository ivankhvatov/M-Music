import SwiftUI

/// Small animated equalizer-style indicator shown in place of a track's number when it's the
/// currently playing track — bars pulse while playing and settle to a fixed height when paused.
struct PlayingIndicator: View {
    var isPlaying: Bool
    var color: Color = .secondary

    @State private var animate = false

    private let bars: [(min: CGFloat, max: CGFloat, duration: Double)] = [
        (4, 13, 0.45),
        (4, 18, 0.6),
        (4, 10, 0.5),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars.indices, id: \.self) { index in
                let bar = bars[index]
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: animate ? bar.max : bar.min)
                    .animation(
                        .easeInOut(duration: bar.duration).repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .frame(width: 20, height: 18, alignment: .bottom)
        .onAppear { animate = isPlaying }
        .onChange(of: isPlaying) { _, newValue in
            animate = newValue
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        PlayingIndicator(isPlaying: true)
        PlayingIndicator(isPlaying: false)
    }
    .padding()
    .background(Color.black)
}
