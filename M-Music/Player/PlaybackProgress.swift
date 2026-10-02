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

    /// The newest position reported, whether or not it was published.
    private var latestTime: TimeInterval = 0

    /// Assigned only on change, so an unchanged value never announces itself.
    ///
    /// The position is published only while the expanded player is on screen: its scrubber is the
    /// only reader, and while the mini player is docked that scrubber sits hidden in an
    /// always-mounted view tree — so publishing twice a second re-ran its body (and a slider
    /// rebuild) on every screen of the app for nothing. `syncNow()` catches it up on expand.
    func update(currentTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
        if let currentTime {
            latestTime = currentTime
            if !PlayerPresentation.shared.accessoryVisible, currentTime != self.currentTime {
                self.currentTime = currentTime
            }
        }
        if let duration, duration != self.duration { self.duration = duration }
    }

    /// Publishes the latest position that was held back while the player was collapsed.
    func syncNow() {
        if latestTime != currentTime { currentTime = latestTime }
    }
}
