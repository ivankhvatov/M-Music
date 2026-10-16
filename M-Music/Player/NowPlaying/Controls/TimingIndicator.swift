import SwiftUI

/// The scrubber row: elapsed/remaining time labels around an `ElasticSlider` bound to real
/// playback position, seeking on release.
struct TimingIndicator: View {
    /// Not observed: only the position, via `progress`, drives this view.
    private let player = PlayerManager.shared
    @ObservedObject private var playback = PlaybackProgress.shared
    let spacing: CGFloat
    /// Where the bar is drawn: the song's position, carried a little ahead of the last update — see
    /// `follow` — or the finger's while the bar is dragged.
    @State private var progress: Double = 0
    /// The position as the last update gave it, which the labels show.
    @State private var reported: Double = 0
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
                    reported = progress
                    player.seek(to: progress)
                }
            }
        )
        .sliderStyle(.playbackProgress)
        .frame(height: 60)
        .transformEffect(.identity)
        .onChange(of: playback.currentTime) {
            guard !isDragging else { return }
            follow(playback.currentTime)
        }
        .onAppear {
            reported = playback.currentTime
            progress = playback.currentTime
        }
    }

    /// The position comes in twice a second. Each time, the bar moves on at the song's pace to
    /// where the next update will find it, so it runs on continuously instead of stepping ahead
    /// twice a second; the labels, which are numbers, keep to the updates. Anything but an
    /// ordinary step — a seek, another song, the song not playing — puts the bar there at once.
    private func follow(_ position: Double) {
        let step = position - reported
        reported = position
        guard player.isPlaying, step > 0, step <= 1 else {
            settle(at: position)
            return
        }
        withAnimation(.linear(duration: step)) { progress = min(position + step, range.upperBound) }
    }

    /// Puts the bar at `position`, from wherever it has got to — and in a moment, not at once: a
    /// value set without animation over the one under way put the bar back to where that began,
    /// and let it run on again. A pause lands here too, with the song's exact position, which the
    /// bar — at the song's position, give or take the little the update lags — is already at.
    private func settle(at position: Double) {
        withAnimation(.linear(duration: 0.08)) { progress = position }
    }
}

private extension TimingIndicator {
    func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.top, 11)
    }

    /// What the labels show: the finger's position while dragging, otherwise the song's.
    private var shown: Double { isDragging ? progress : reported }

    var leadingLabelText: String {
        shown.asTimeString
    }

    var trailingLabelText: String {
        ((range.upperBound - shown) * -1.0).asTimeString
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

