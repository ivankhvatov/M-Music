import Foundation

/// Playback position and track length, kept out of `PlayerManager` on purpose.
///
/// `currentTime` changes twice a second while anything plays. When it was a `@Published` property
/// of `PlayerManager`, every view observing the player — the expanded player's whole subtree, the
/// mini player, the transport buttons, and a `PlayingIndicator` overlay on every visible row —
/// re-evaluated its body on each of those ticks, though only the scrubber actually shows the
/// value. Views that draw the position (`TimingIndicator`) observe this object instead; everything
/// else observes `PlayerManager` and now only hears about real changes (track, play/pause, …).
@MainActor
final class PlaybackProgress: ObservableObject {
    static let shared = PlaybackProgress()

    @Published fileprivate(set) var currentTime: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0

    private init() {}

    /// Assigned only on change, so an unchanged value never announces itself.
    func update(currentTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
        if let currentTime, currentTime != self.currentTime { self.currentTime = currentTime }
        if let duration, duration != self.duration { self.duration = duration }
    }
}
