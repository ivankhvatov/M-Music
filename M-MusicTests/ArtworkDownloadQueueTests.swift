import Foundation
import Testing
@testable import M_Music

/// A server the test answers by hand.
private final class HandServer: @unchecked Sendable {
    private let lock = NSLock()
    private var startedNames: [String] = []
    private var storedNames: [String] = []
    private var pending: [String: CheckedContinuation<Data?, Never>] = [:]

    var started: [String] { lock.withLock { startedNames } }
    var stored: [String] { lock.withLock { storedNames } }

    func queue(limit: Int = 4) -> ArtworkDownloadQueue {
        ArtworkDownloadQueue(
            limit: limit,
            fetch: { url in
                await withCheckedContinuation { continuation in
                    self.lock.withLock {
                        self.startedNames.append(url.lastPathComponent)
                        self.pending[url.lastPathComponent] = continuation
                    }
                }
            },
            store: { _, key in self.lock.withLock { self.storedNames.append(key) } }
        )
    }

    func answer(_ name: String) async {
        await until { self.lock.withLock { self.pending[name] != nil } }
        lock.withLock { pending.removeValue(forKey: name) }?.resume(returning: Data(name.utf8))
    }
}

private func until(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

/// Asks for `name`, and returns once the queue has taken the request in.
private func ask(
    _ queue: ArtworkDownloadQueue, _ name: String, _ priority: ArtworkDownloadQueue.Priority = .visible,
    cancellable: Bool = true
) async -> Task<Data?, Never> {
    let before = queue.waiterCount(for: name)
    let task = Task {
        await queue.data(for: URL(string: "http://x.test/\(name)")!, key: name, priority: priority, cancellable: cancellable)
    }
    await until { queue.waiterCount(for: name) > before }
    return task
}

struct ArtworkDownloadQueueTests {
    @Test func anImageIsDownloadedOnceAndSavedForAllWhoAsk() async {
        let server = HandServer()
        let queue = server.queue()
        let first = await ask(queue, "a")
        let second = await ask(queue, "a", .ahead)
        await server.answer("a")
        #expect(await first.value == Data("a".utf8))
        #expect(await second.value == Data("a".utf8))
        #expect(server.started == ["a"])
        #expect(server.stored == ["a"])
    }

    @Test func aDownloadNobodyWaitsForAnyMoreIsNeverStarted() async {
        let server = HandServer()
        let queue = server.queue(limit: 1)
        let first = await ask(queue, "a")
        let scrolledPast = await ask(queue, "b")
        scrolledPast.cancel()
        #expect(await scrolledPast.value == nil)
        await server.answer("a")
        _ = await first.value
        let next = await ask(queue, "c")
        await server.answer("c")
        _ = await next.value
        #expect(server.started == ["a", "c"])
    }

    @Test func aDownloadUnderWayIsFinishedAndSaved() async {
        let server = HandServer()
        let queue = server.queue()
        let task = await ask(queue, "a")
        await until { server.started == ["a"] }
        task.cancel()
        #expect(await task.value == nil)
        await server.answer("a")
        await until { server.stored == ["a"] }
    }

    @Test func whatIsOnScreenGoesFirstNewestFirstThenTheRestInOrder() async {
        let server = HandServer()
        let queue = server.queue(limit: 1)
        _ = await ask(queue, "running")
        _ = await ask(queue, "bulk", .bulk)
        _ = await ask(queue, "next1", .destination)
        _ = await ask(queue, "ahead1", .ahead)
        _ = await ask(queue, "seen1")
        _ = await ask(queue, "ahead2", .ahead)
        _ = await ask(queue, "seen2")
        for name in ["running", "seen2", "seen1", "ahead1", "ahead2", "next1", "bulk"] {
            await server.answer(name)
        }
        #expect(server.started == ["running", "seen2", "seen1", "ahead1", "ahead2", "next1", "bulk"])
    }

    @Test func aSlotIsKeptForWhatIsOnScreen() async {
        let server = HandServer()
        let queue = server.queue(limit: 2)
        _ = await ask(queue, "a", .ahead)
        _ = await ask(queue, "b", .ahead)
        await until { server.started == ["a"] }
        _ = await ask(queue, "c")
        await until { server.started == ["a", "c"] }
        await server.answer("a")
        await until { server.started == ["a", "c", "b"] }
        await server.answer("b")
        await server.answer("c")
    }

    @Test func aRowComingOnScreenBringsItsDownloadForward() async {
        let server = HandServer()
        let queue = server.queue(limit: 2)
        _ = await ask(queue, "a", .ahead)
        _ = await ask(queue, "b", .ahead)
        await until { server.started == ["a"] }
        let row = await ask(queue, "b")
        await until { server.started == ["a", "b"] }
        await server.answer("b")
        _ = await row.value
        await server.answer("a")
    }

    @Test func aSaveForDownloadedMusicIsMadeEvenIfItsCallerGoes() async {
        let server = HandServer()
        let queue = server.queue(limit: 1)
        _ = await ask(queue, "a")
        let save = await ask(queue, "kept", .bulk, cancellable: false)
        save.cancel()
        await server.answer("a")
        await server.answer("kept")
        #expect(await save.value == Data("kept".utf8))
        #expect(server.stored == ["a", "kept"])
    }

    @Test func cancellingEverythingAnswersNothingAndSavesNothingLate() async {
        let server = HandServer()
        let queue = server.queue(limit: 1)
        let running = await ask(queue, "a")
        let queued = await ask(queue, "b")
        await until { server.started == ["a"] }
        queue.cancelAll()
        #expect(await running.value == nil)
        #expect(await queued.value == nil)
        await server.answer("a")
        let after = await ask(queue, "c")
        await server.answer("c")
        #expect(await after.value != nil)
        #expect(server.stored == ["c"])
        #expect(server.started == ["a", "c"])
    }
}
