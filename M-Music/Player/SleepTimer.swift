import Foundation

/// The sleep timer behind the player's "Set timer": once it runs out, playback is paused.
///
/// It's kept as the moment it ends (`endDate`) rather than as a countdown that's ticked down, so
/// what's left is always read off the clock and can't drift. The wait runs on the continuous
/// clock, which keeps counting while the device sleeps.
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// What's left in whole seconds, for what shows it. A separate object from the timer itself, so
    /// the one view that follows the countdown is the only one redrawn as it ticks, and only when the
    /// shown number changes.
    let countdown = SleepTimerCountdown()

    /// When the timer runs out — `nil` while none is running.
    @Published private(set) var endDate: Date?

    private var task: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    var isRunning: Bool { endDate != nil }

    /// Seconds left, never negative; 0 while no timer runs.
    func remaining(at date: Date = .now) -> TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    /// Starts a timer of `seconds`, replacing a running one. Does nothing for zero.
    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        task?.cancel()
        endDate = Date().addingTimeInterval(seconds)
        countdown.seconds = Int(seconds.rounded(.up))
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.finish()
        }
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            // Woken only when the shown number is due to change, not on a fixed beat.
            while !Task.isCancelled, let wait = self?.tick() {
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tickTask?.cancel()
        tickTask = nil
        endDate = nil
    }

    private func finish() {
        stop()
        PlayerManager.shared.pause()
    }

    /// Publishes the seconds left if they've changed; returns how long until they next do, or `nil`
    /// once the timer is over.
    private func tick() -> TimeInterval? {
        let left = remaining()
        guard left > 0 else { return nil }
        let shown = Int(left.rounded(.up))
        if countdown.seconds != shown { countdown.seconds = shown }
        // The number drops to `shown - 1` once `left` does; a hair more, so it's past it.
        return left - Double(shown - 1) + 0.02
    }

    /// "1:05:09" from an hour on, otherwise "4:30" — what's left, as the menu shows it.
    static func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// The sleep timer's remaining whole seconds. See `SleepTimer.countdown`.
@MainActor
final class SleepTimerCountdown: ObservableObject {
    @Published fileprivate(set) var seconds = 0
}
