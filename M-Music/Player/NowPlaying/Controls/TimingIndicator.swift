import SwiftUI

/// The scrubber row: elapsed/remaining time labels around an `ElasticSlider` bound to real
/// playback position, seeking on release.
///
/// While the song plays, the bar and the labels are drawn on every frame of a `TimelineView`, each
/// time from where the player says the song is (`PlayerManager.livePosition`). The position is
/// asked for, never worked out between the player's updates — carried forward on a clock of its
/// own it drifted ahead of the song, and was pulled back at pauses and after skips.
struct TimingIndicator: View {
    private let player = PlayerManager.shared
    /// Its changes — a pause or a seek landing, a new song — draw the bar when no frames do.
    @ObservedObject private var playback = PlaybackProgress.shared
    let spacing: CGFloat
    /// The finger's position, while the bar is dragged.
    @State private var progress: Double = 0
    @State private var isDragging = false
    /// Whether the song is advancing (see `PlayerManager.isAdvancingPublisher`).
    @State private var advancing = false
    /// Observed, for the one thing: the player being up. Docked, nothing shows the bar.
    private let presentation = PlayerPresentation.shared

    private var range: ClosedRange<Double> { 0 ... max(playback.duration, 1) }

    /// Frames are drawn only while there's something to see move.
    private var drawsFrames: Bool { advancing && !presentation.accessoryVisible && !isDragging }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !drawsFrames)) { _ in
            // Asked for once per frame, so the bar and the labels agree.
            let position = isDragging ? progress : player.livePosition
            ElasticSlider(
                value: Binding(get: { position }, set: { progress = $0 }),
                in: range,
                leadingLabel: { TimeLabel(seconds: position).equatable() },
                trailingLabel: { TimeLabel(seconds: position - range.upperBound).equatable() },
                onActive: { active in
                    isDragging = active
                    if !active {
                        player.seek(to: progress)
                    }
                }
            )
        }
        .sliderStyle(.playbackProgress)
        .frame(height: 60)
        .transformEffect(.identity)
        .onReceive(player.isAdvancingPublisher) { advancing = $0 }
    }
}

/// A time as `m:ss` (negative for the time left). Equatable on the whole second it shows, so that
/// drawing it on every frame only formats it — which isn't cheap — when it changes.
private struct TimeLabel: View, Equatable {
    let seconds: Double

    var body: some View {
        Text(seconds.asTimeString)
            .font(.caption2.monospacedDigit())
            .padding(.top, 11)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        Int(lhs.seconds.rounded(.towardZero)) == Int(rhs.seconds.rounded(.towardZero))
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
