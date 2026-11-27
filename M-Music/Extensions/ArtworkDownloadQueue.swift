import Foundation

/// Which artwork downloads run, and in what order.
///
/// One download per image, however many ask for it. Only a few run at once, and which one starts
/// next depends on who is waiting: a row on screen before one about to scroll into view, that one
/// before the next screen's images, and those before filling the cache in the background — with a
/// slot always kept free for what's on screen. A download nobody is waiting for any more (its row
/// scrolled past) is dropped if it hasn't started: a fast scroll through thousands of rows used to
/// leave all of theirs queued ahead of the rows where it stopped. One already running is left to
/// finish and be saved — dropping it would throw away the connection and what has arrived.
final class ArtworkDownloadQueue: @unchecked Sendable {
    enum Priority: Int, Comparable, Sendable {
        /// Filling the cache for later.
        case bulk
        /// The images of a screen that might be opened next.
        case destination
        /// Rows about to scroll into view.
        case ahead
        /// Something on screen is waiting.
        case visible

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Waiter {
        let priority: Priority
        let continuation: CheckedContinuation<Data?, Never>
    }

    private final class Job {
        let key: String
        let url: URL
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        /// When it was last asked for: what's on screen goes newest first, everything else in order.
        var asked = 0

        init(key: String, url: URL) {
            self.key = key
            self.url = url
        }

        var priority: Priority { waiters.values.map(\.priority).max() ?? .bulk }
    }

    /// Whether the caller's task was cancelled before it had joined a job.
    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        var isCancelled = false
    }

    private let limit: Int
    /// How many `.bulk` downloads run at once.
    private let bulkLimit: Int
    private let fetch: @Sendable (URL) async -> Data?
    private let store: @Sendable (Data, String) -> Void

    private let lock = NSLock()
    private var queued: [String: Job] = [:]
    private var running: [String: Job] = [:]
    private var asks = 0

    /// `fetch` gets an image's bytes; `store` saves them, before anyone waiting hears of them.
    init(
        limit: Int = 4, bulkLimit: Int = 2,
        fetch: @escaping @Sendable (URL) async -> Data?,
        store: @escaping @Sendable (Data, String) -> Void
    ) {
        self.limit = limit
        self.bulkLimit = bulkLimit
        self.fetch = fetch
        self.store = store
    }

    /// The bytes of `url`, filed under `key`: `nil` if they couldn't be had, or the caller stopped
    /// waiting. With `cancellable` false the download is made even if the caller goes away.
    func data(for url: URL, key: String, priority: Priority, cancellable: Bool = true) async -> Data? {
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if cancellable, ticket.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }
                    let job = running[key] ?? queued[key] ?? Job(key: key, url: url)
                    // A waiter that may not be dropped is filed under an id no cancellation knows.
                    let id = cancellable ? ticket.id : UUID()
                    job.waiters[id] = Waiter(priority: priority, continuation: continuation)
                    asks += 1
                    job.asked = asks
                    if running[key] == nil { queued[key] = job }
                    startWhatCan()
                }
            }
        } onCancel: {
            guard cancellable else { return }
            lock.withLock {
                ticket.isCancelled = true
                guard let job = running[key] ?? queued[key],
                      let waiter = job.waiters.removeValue(forKey: ticket.id) else { return }
                waiter.continuation.resume(returning: nil)
                if job.waiters.isEmpty, queued[key] === job { queued[key] = nil }
                // Its priority may have dropped, which can free a slot for another.
                startWhatCan()
            }
        }
    }

    /// How many are waiting for the download filed under `key`, for tests.
    func waiterCount(for key: String) -> Int {
        lock.withLock { (running[key] ?? queued[key])?.waiters.count ?? 0 }
    }

    /// Everything stops: what's on disk is about to be thrown away (another server).
    func cancelAll() {
        lock.withLock {
            let jobs = Array(queued.values) + Array(running.values)
            queued = [:]
            running = [:]
            for job in jobs {
                job.task?.cancel()
                for waiter in job.waiters.values { waiter.continuation.resume(returning: nil) }
                job.waiters = [:]
            }
        }
    }

    /// Starts queued jobs while there's room. Call with `lock` held.
    private func startWhatCan() {
        while running.count < limit {
            // A slot is kept free for what's on screen, and background filling takes only a few.
            let others = running.values.filter { $0.priority < .visible }.count
            let bulk = running.values.filter { $0.priority == .bulk }.count
            let reserved = max(limit - 1, 1)
            let next = queued.values
                .filter { job in
                    switch job.priority {
                    case .visible: true
                    case .ahead, .destination: others < reserved
                    case .bulk: others < reserved && bulk < bulkLimit
                    }
                }
                .max { lhs, rhs in
                    let (left, right) = (lhs.priority, rhs.priority)
                    if left != right { return left < right }
                    return left == .visible ? lhs.asked < rhs.asked : lhs.asked > rhs.asked
                }
            guard let job = next else { return }
            queued[job.key] = nil
            running[job.key] = job
            job.task = Task { [weak self, fetch] in
                let data = await fetch(job.url)
                self?.finish(job, with: data)
            }
        }
    }

    private func finish(_ job: Job, with data: Data?) {
        // Not for a job `cancelAll` has dropped: its bytes belong to what was thrown away.
        guard lock.withLock({ running[job.key] === job }) else { return }
        if let data { store(data, job.key) }
        lock.withLock {
            guard running[job.key] === job else { return }
            running[job.key] = nil
            for waiter in job.waiters.values { waiter.continuation.resume(returning: data) }
            job.waiters = [:]
            startWhatCan()
        }
    }
}
