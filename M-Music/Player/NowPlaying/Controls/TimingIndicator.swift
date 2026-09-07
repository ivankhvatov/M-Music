import SwiftUI

/// The scrubber row: elapsed/remaining time labels around an `ElasticSlider` bound to real
/// playback position, seeking on release.
struct TimingIndicator: View {
    @ObservedObject private var player = PlayerManager.shared
    let spacing: CGFloat
    @State private var progress: Double = 0
    @State private var isDragging = false

    private var range: ClosedRange<Double> { 0 ... max(player.duration, 1) }

    var body: some View {
        ElasticSlider(
            value: $progress,
            in: range,
            leadingLabel: { label(leadingLabelText) },
            trailingLabel: { label(trailingLabelText) },
            onActive: { active in
                isDragging = active
                if !active {
                    player.seek(to: progress)
                }
            }
        )
        .sliderStyle(.playbackProgress)
        .frame(height: 60)
        .transformEffect(.identity)
        .onChange(of: player.currentTime) {
            guard !isDragging else { return }
            progress = player.currentTime
        }
        .onAppear {
            progress = player.currentTime
        }
    }
}

private extension TimingIndicator {
    func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.top, 11)
    }

    var leadingLabelText: String {
        progress.asTimeString
    }

    var trailingLabelText: String {
        ((range.upperBound - progress) * -1.0).asTimeString
    }
}

extension ElasticSliderConfig {
    static var playbackProgress: Self {
        Self(
            labelLocation: .bottom,
            maxStretch: 0,
            minimumTrackActiveColor: .white,
            minimumTrackInactiveColor: .white,
            maximumTrackColor: .white.opacity(0.3),
            blendMode: .normal,
            syncLabelsStyle: true
        )
    }
}

private extension BinaryFloatingPoint {
    var asTimeString: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: TimeInterval(self)) ?? ""
    }
}
