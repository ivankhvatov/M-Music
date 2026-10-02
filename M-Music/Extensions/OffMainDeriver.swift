import Foundation

/// Runs a derivation — sorting, grouping, filtering a whole-library list — off the main actor and
/// applies only the newest result back on it.
///
/// A library screen can hold tens of thousands of items; sorting them (an ICU collation per
/// comparison) and filtering on every search keystroke used to run synchronously on the main
/// actor, which froze the screen for the better part of a second right as it opened. The work
/// itself is a pure function of value inputs captured when it's requested (all `Sendable`), so it
/// runs in a detached task, and `generation` makes sure a result that has been superseded by a
/// newer request — or cancelled with the screen — is never applied.
///
/// One lives in each list screen's `@State` (a stable reference, so closures from older
/// `body` evaluations still compare against the same counter).
@MainActor
final class OffMainDeriver {
    private var generation = 0
    private var task: Task<Void, Never>?

    /// Whether a derivation is in flight, i.e. what's on screen is about to be replaced.
    private(set) var isPending = false

    /// Set when the items or the sort changed, so the next derivation must re-sort. Cleared only
    /// when a derivation that included the sort is applied — a request superseded before that
    /// (which is dropped, never applied) leaves it set for the request that replaced it.
    var sortStale = true

    /// - Parameters:
    ///   - delay: waits this long first, so a burst of requests (search keystrokes) coalesces
    ///     into the last one.
    ///   - work: the derivation. Captures value inputs only; runs off the main actor.
    ///   - apply: assigns the result; runs on the main actor, only if still the newest request.
    func run<Output: Sendable>(
        delay: Duration? = nil,
        _ work: @escaping @Sendable () -> Output,
        apply: @escaping @MainActor (Output) -> Void
    ) {
        generation += 1
        let mine = generation
        task?.cancel()
        isPending = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let output = work()
            if Task.isCancelled { return }
            await self?.deliver(output, generation: mine, apply: apply)
        }
    }

    private func deliver<Output: Sendable>(
        _ output: Output, generation: Int, apply: @MainActor (Output) -> Void
    ) {
        guard self.generation == generation else { return }
        isPending = false
        apply(output)
    }

    /// Drops whatever is in flight — for when the screen's data is wiped.
    func cancel() {
        generation += 1
        task?.cancel()
        isPending = false
    }
}
