import Foundation
import Testing
@testable import M_Music

/// Answers every request with a canned `getScanStatus` body and counts them.
private final class ScanStatusStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastScan = "scan-1"
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var failWith: URLError.Code?
    private static let lock = NSLock()

    static func reset(lastScan: String = "scan-1") {
        lock.lock(); defer { lock.unlock() }
        self.lastScan = lastScan
        requestCount = 0
        failWith = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let scan = Self.lastScan
        let failure = Self.failWith
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","scanStatus":{"scanning":false,"count":1,"lastScan":"\#(scan)"}}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records what a fake source was asked to do.
private actor Log {
    var fetches = 0
    var writes: [[Int]] = []
    func fetched() { fetches += 1 }
    func wrote(_ value: [Int]) { writes.append(value) }
}

private func makeClient() -> SubsonicClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScanStatusStub.self]
    let client = SubsonicClient(session: URLSession(configuration: config))
    // A unique server per client: revalidation tokens are stored per server + user.
    client.credentials = SubsonicCredentials(
        baseURL: URL(string: "https://\(UUID().uuidString.lowercased()).test")!, username: "u", password: "p"
    )
    return client
}

private func source(
    cache: [Int]? = nil, server: [Int] = [1, 2, 3], scanList: LibraryRevalidation.List? = nil,
    fetchError: Error? = nil, delay: Duration = .zero, log: Log
) -> LibrarySource<[Int]> {
    LibrarySource(
        scanList: scanList,
        isEmpty: \.isEmpty,
        readCache: { cache },
        writeCache: { await log.wrote($0) },
        fetch: {
            await log.fetched()
            if delay != .zero { try await Task.sleep(for: delay) }
            if let fetchError { throw fetchError }
            return server
        }
    )
}

private func collect(_ stream: AsyncStream<LibraryLoad<[Int]>>) async -> [String] {
    var events: [String] = []
    for await event in stream {
        switch event {
        case .cached(let v): events.append("cached\(v)")
        case .fresh(let v): events.append("fresh\(v)")
        case .upToDate: events.append("upToDate")
        case .failed: events.append("failed")
        }
    }
    return events
}

@Suite(.serialized)
struct LibraryLoaderTests {
    @Test func showsCacheThenFreshAndPersists() async {
        let log = Log()
        let events = await collect(LibraryLoader.load(source(cache: [1], server: [1, 2], log: log), shown: nil))
        #expect(events == ["cached[1]", "fresh[1, 2]"])
        #expect(await log.writes == [[1, 2]])
    }

    @Test func unchangedServerDataIsUpToDateAndNotRewritten() async {
        let log = Log()
        let events = await collect(LibraryLoader.load(source(cache: [1, 2], server: [1, 2], log: log), shown: nil))
        #expect(events == ["cached[1, 2]", "upToDate"])
        #expect(await log.writes.isEmpty)
    }

    @Test func alreadyShownValueSkipsTheCacheRead() async {
        let log = Log()
        let events = await collect(LibraryLoader.load(source(cache: [9], server: [1], log: log), shown: [1]))
        #expect(events == ["upToDate"])
    }

    @Test func emptyShownValueStillReadsTheCache() async {
        let log = Log()
        let events = await collect(LibraryLoader.load(source(cache: [7], server: [7], log: log), shown: []))
        #expect(events == ["cached[7]", "upToDate"])
    }

    @Test func failureWithoutAndWithBaselineIsReported() async {
        let log = Log()
        let boom = URLError(.notConnectedToInternet)
        let events = await collect(LibraryLoader.load(source(cache: [1], fetchError: boom, log: log), shown: nil))
        #expect(events == ["cached[1]", "failed"])
        #expect(await log.writes.isEmpty)
    }

    @Test func scanGateSkipsTheDownloadWhenNothingChanged() async {
        ScanStatusStub.reset(lastScan: "scan-1")
        let client = makeClient()
        let revalidation = LibraryRevalidation()
        let log = Log()
        let first = await collect(LibraryLoader.load(
            source(cache: [1], server: [1], scanList: .albums, log: log), shown: nil, revalidation: revalidation, client: client))
        #expect(first == ["cached[1]", "upToDate"])          // never synced → downloads once
        #expect(await log.fetches == 1)

        let second = await collect(LibraryLoader.load(
            source(cache: [1], server: [1], scanList: .albums, log: log), shown: nil, revalidation: revalidation, client: client))
        #expect(second == ["cached[1]", "upToDate"])
        #expect(await log.fetches == 1)                        // scan unchanged → no second download
    }

    @Test func forceBypassesTheScanGate() async {
        ScanStatusStub.reset()
        let client = makeClient()
        let revalidation = LibraryRevalidation()
        let log = Log()
        _ = await collect(LibraryLoader.load(
            source(cache: [1], scanList: .songs, log: log), shown: nil, revalidation: revalidation, client: client))
        _ = await collect(LibraryLoader.load(
            source(cache: [1], scanList: .songs, log: log), shown: nil, force: true, revalidation: revalidation, client: client))
        #expect(await log.fetches == 2)
    }

    @Test func aNewScanTriggersARedownload() async {
        ScanStatusStub.reset(lastScan: "scan-1")
        let client = makeClient()
        let revalidation = LibraryRevalidation()
        let log = Log()
        _ = await collect(LibraryLoader.load(
            source(cache: [1], scanList: .artists, log: log), shown: nil, revalidation: revalidation, client: client))
        ScanStatusStub.reset(lastScan: "scan-2")
        _ = await collect(LibraryLoader.load(
            source(cache: [1], scanList: .artists, log: log), shown: nil, revalidation: revalidation, client: client))
        #expect(await log.fetches == 2)
    }

    @Test func cancellingMidFetchEmitsNothingAndDoesNotMarkSynced() async {
        ScanStatusStub.reset()
        let client = makeClient()
        let revalidation = LibraryRevalidation()
        let log = Log()
        let task = Task {
            await collect(LibraryLoader.load(
                source(cache: [1], server: [2], scanList: .albums, delay: .seconds(5), log: log),
                shown: nil, revalidation: revalidation, client: client))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let events = await task.value
        #expect(events == ["cached[1]"])
        #expect(await log.writes.isEmpty)
        // Not marked synced: the next open must still download.
        let check = await revalidation.check(.albums, client: client)
        #expect(check.needsRefetch)
    }

    @Test func aCompletedFetchIsStillPersistedIfTheConsumerLeavesRightAfter() async {
        let log = Log()
        var iterator = LibraryLoader.load(source(cache: nil, server: [4, 5], log: log), shown: nil).makeAsyncIterator()
        let first = await iterator.next()
        guard case .fresh(let value)? = first else { Issue.record("expected .fresh"); return }
        #expect(value == [4, 5])
        // Drop the iterator (consumer gone) and give the detached persist a moment.
        _ = consume iterator
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await log.writes == [[4, 5]])
    }

    @Test func transportErrorsKeepTheirTypeSoCallersCanRetryOrIgnoreThem() async {
        ScanStatusStub.reset()
        ScanStatusStub.failWith = .notConnectedToInternet
        let client = makeClient()
        await #expect(throws: URLError.self) { try await client.getScanStatus() }
    }

    @Test func identicalConcurrentGetsShareOneRequest() async throws {
        ScanStatusStub.reset()
        let client = makeClient()
        async let a = client.getScanStatus()
        async let b = client.getScanStatus()
        async let c = client.getScanStatus()
        _ = try await (a, b, c)
        #expect(ScanStatusStub.requestCount < 3)
        #expect(ScanStatusStub.requestCount >= 1)
    }
}
