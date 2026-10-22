import Foundation

/// Whether the user is scrolling a screen right now, readable from any thread. Background work
/// that nobody is waiting for — warming images ahead — waits it out: during a fling the CPU is
/// better spent on drawing, and everything that was held back runs once the scroll has settled.
/// Work that a visible card is waiting on is never held.
final class ScrollActivity: @unchecked Sendable {
    static let shared = ScrollActivity()

    /// How long after a scroll ends background work stays held, so a flick that is about to start
    /// again doesn't let it in between.
    static let settleDelay: TimeInterval = 0.15

    private let lock = NSLock()
    private var scrolling = false
    private var endedAt = Date.distantPast

    /// A scroll view started or stopped moving.
    func set(scrolling isScrolling: Bool, at now: Date = Date()) {
        lock.withLock {
            if scrolling && !isScrolling { endedAt = now }
            scrolling = isScrolling
        }
    }

    /// Whether background work should hold off.
    func isBusy(at now: Date = Date()) -> Bool {
        lock.withLock { scrolling || now.timeIntervalSince(endedAt) < Self.settleDelay }
    }

    /// Returns once nothing is scrolling (or the task is cancelled).
    func waitUntilIdle() async {
        while isBusy(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
