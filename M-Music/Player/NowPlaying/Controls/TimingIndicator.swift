import SwiftUI

/// The scrubber row: elapsed/remaining time labels around an `ElasticSlider` bound to real
/// playback position, seeking on release.
struct TimingIndicator: View {
    /// Not observed: only the position, via `progress`, drives this view.
    private let player = PlayerManager.shared
    @ObservedObject private var playback = PlaybackProgress.shared
    let spacing: CGFloat
    @State private var progress: Double = 0
    @State private var isDragging = false

    private var range: ClosedRange<Double> { 0 ... max(playback.duration, 1) }

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
        .onChange(of: playback.currentTime) {
            guard !isDragging else { return }
            progress = playback.currentTime
        }
        .onAppear {
            progress = playback.currentTime
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
        TimeFormatter.shared.string(from: TimeInterval(self)) ?? ""
    }
}

/// One shared formatter: it runs for both labels on every scrubber update, and allocating and
/// configuring a `DateComponentsFormatter` each time costs far more than formatting.
private enum TimeFormatter {
    static let shared: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
