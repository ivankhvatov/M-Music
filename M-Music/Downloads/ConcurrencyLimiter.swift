import Foundation

/// Bounds how many callers can hold a slot at once; extra callers queue FIFO and are resumed in
/// the order they arrived as slots free up. Used to cap concurrent downloads so queuing an entire
/// album doesn't open dozens of connections at once.
///
/// `acquire()` is cancellation-aware: a caller that's no longer interested in the slot (e.g. a
/// cancelled download) is dropped from the queue instead of running its held-up work anyway once
/// its turn eventually comes.
///
/// Ported from Shelv's `ShelvCore/Services/ConcurrencyLimiter.swift`.
actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private(set) var activeCount = 0
    private var waitQueue: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    // Cancellations that arrived before the matching waiter was enqueued (the `onCancel` handler
    // can fire immediately, ahead of `operation` below, if the task was already cancelled).
    // Consulted once by that waiter's enqueue step.
    private var preCancelledIDs: Set<UUID> = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Returns `false` without granting a slot if the caller is cancelled, either already or
    /// while queued.
    @discardableResult
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if activeCount < maxConcurrent {
            activeCount += 1
            return true
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if preCancelledIDs.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waitQueue.append((id, continuation))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelWaiter(id) }
        }
        return granted
    }

    func release() {
        activeCount -= 1
        guard !waitQueue.isEmpty else { return }
        let next = waitQueue.removeFirst()
        activeCount += 1
        next.continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waitQueue.firstIndex(where: { $0.id == id }) else {
            preCancelledIDs.insert(id)
            return
        }
        let removed = waitQueue.remove(at: index)
        removed.continuation.resume(returning: false)
    }
}
