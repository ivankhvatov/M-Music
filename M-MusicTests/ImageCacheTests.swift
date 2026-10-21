import Foundation
import Testing
import UIKit
@testable import M_Music

/// Answers every request with whatever `Responder.current` says and counts them.
private final class ImageStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ImageStub.png
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static let png: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }()

    static func reset(status: Int = 200, body: Data = ImageStub.png) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = body
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let (status, body) = (Self.status, Self.body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Two scratch directories standing in for `Caches/` and `Application Support/`.
private struct Directories {
    let regular = FileManager.default.temporaryDirectory.appendingPathComponent("img-regular-\(UUID().uuidString)")
    let permanent = FileManager.default.temporaryDirectory.appendingPathComponent("img-permanent-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: regular, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: permanent, withIntermediateDirectories: true)
    }

    /// A fresh `ImageCache` over these directories — and so an empty memory tier, like a relaunch.
    func makeCache() -> ImageCache {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageStub.self]
        return ImageCache(regularDirectory: regular, permanentDirectory: permanent, session: URLSession(configuration: config))
    }

    func fileCount(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    /// Wipes the regular cache the way iOS does under storage pressure — the folder itself too.
    func purgeRegular() {
        try? FileManager.default.removeItem(at: regular)
    }
}

private func coverURL(_ id: String, size: Int? = nil, token: String = "t1") -> URL {
    var string = "http://example.test/rest/getCoverArt?id=\(id)&u=demo&t=\(token)&s=salt&v=1.16.1&c=M-Music&f=json"
    if let size { string += "&size=\(size)" }
    return URL(string: string)!
}

@Suite(.serialized)
struct ImageCacheTests {
    @Test func browsingFillsOnlyTheRegularCache() async {
        ImageStub.reset()
        let dirs = Directories()
        let image = await dirs.makeCache().load(coverURL("al-1"))
        #expect(image != nil)
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.regular) == 1)
        #expect(dirs.fileCount(dirs.permanent) == 0)
    }

    @Test func aRegularCacheHitNeverTouchesTheNetworkOrThePermanentCache() async {
        ImageStub.reset()
        let dirs = Directories()
        _ = await dirs.makeCache().load(coverURL("al-1"))
        // A different signature for the same image, through a fresh cache (empty memory).
        let image = await dirs.makeCache().load(coverURL("al-1", token: "t2"))
        #expect(image != nil)
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.permanent) == 0)
    }

    @Test func savePermanentlyWritesBothCaches() async {
        ImageStub.reset()
        let dirs = Directories()
        #expect(await dirs.makeCache().savePermanently(coverURL("al-1")))
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.regular) == 1)
        #expect(dirs.fileCount(dirs.permanent) == 1)
        // Already in both: nothing more to do.
        #expect(await dirs.makeCache().savePermanently(coverURL("al-1", token: "t2")))
        #expect(ImageStub.requestCount == 1)
    }

    @Test func aPurgedRegularCacheIsRestoredFromThePermanentCacheWithoutTheNetwork() async {
        ImageStub.reset()
        let dirs = Directories()
        await dirs.makeCache().savePermanently(coverURL("al-1"))
        dirs.purgeRegular()

        let image = await dirs.makeCache().load(coverURL("al-1"))
        #expect(image != nil)
        #expect(ImageStub.requestCount == 1)            // only the original save
        #expect(dirs.fileCount(dirs.regular) == 1)      // written back, folder recreated
    }

    @Test func prefetchRestoresThePermanentCopyIntoTheRegularCache() async {
        ImageStub.reset()
        let dirs = Directories()
        await dirs.makeCache().savePermanently(coverURL("al-1"))
        dirs.purgeRegular()

        await dirs.makeCache().prefetchOriginalData(coverURL("al-1"))
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.regular) == 1)
    }

    @Test func aMissingFromBothImageComesFromTheServerAndLandsInTheRegularCache() async {
        ImageStub.reset()
        let dirs = Directories()
        await dirs.makeCache().savePermanently(coverURL("al-1"))
        dirs.purgeRegular()
        try? FileManager.default.removeItem(at: dirs.permanent)

        let image = await dirs.makeCache().load(coverURL("al-1"))
        #expect(image != nil)
        #expect(ImageStub.requestCount == 2)
        #expect(dirs.fileCount(dirs.regular) == 1)
    }

    @Test func savePermanentlyFillsWhicheverCacheIsMissingWithoutTheNetwork() async {
        ImageStub.reset()
        let dirs = Directories()
        // Only in the regular cache (it was just browsed).
        _ = await dirs.makeCache().load(coverURL("al-1"))
        #expect(await dirs.makeCache().savePermanently(coverURL("al-1")))
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.permanent) == 1)

        // Only in the permanent cache (the regular one was purged).
        dirs.purgeRegular()
        #expect(await dirs.makeCache().savePermanently(coverURL("al-1")))
        #expect(ImageStub.requestCount == 1)
        #expect(dirs.fileCount(dirs.regular) == 1)
    }

    @Test func thumbnailsAreSeparateEntries() async {
        ImageStub.reset()
        let dirs = Directories()
        await dirs.makeCache().savePermanently(coverURL("al-1"))
        await dirs.makeCache().savePermanently(coverURL("al-1", size: 132))
        #expect(ImageStub.requestCount == 2)
        #expect(dirs.fileCount(dirs.permanent) == 2)
    }

    @Test func errorBodiesAndFailedResponsesAreNeverStored() async {
        let dirs = Directories()

        ImageStub.reset(body: Data(#"{"subsonic-response":{"status":"failed"}}"#.utf8))
        #expect(await dirs.makeCache().load(coverURL("al-1")) == nil)
        #expect(await dirs.makeCache().savePermanently(coverURL("al-1")) == false)

        ImageStub.reset(status: 404)
        #expect(await dirs.makeCache().load(coverURL("al-2")) == nil)
        #expect(await dirs.makeCache().savePermanently(coverURL("al-2")) == false)

        #expect(dirs.fileCount(dirs.regular) == 0)
        #expect(dirs.fileCount(dirs.permanent) == 0)
    }

    @Test func invalidateAllClearsTheRegularCacheButNotThePermanentOne() async {
        ImageStub.reset()
        let dirs = Directories()
        let cache = dirs.makeCache()
        await cache.savePermanently(coverURL("al-1"))
        cache.invalidateAll()
        #expect(dirs.fileCount(dirs.regular) == 0)
        #expect(dirs.fileCount(dirs.permanent) == 1)
    }

    @Test func removeDropsEveryTier() async {
        ImageStub.reset()
        let dirs = Directories()
        let cache = dirs.makeCache()
        await cache.savePermanently(coverURL("al-1"))
        cache.remove(coverURL("al-1", token: "t2"))
        #expect(dirs.fileCount(dirs.regular) == 0)
        #expect(dirs.fileCount(dirs.permanent) == 0)
    }
}

/// In an extension of `ImageCacheTests`, not a suite of their own: they share `ImageStub`'s
/// request counter, so they must not run in parallel with the tests above.
extension ImageCacheTests {
    @Test func preloadingFromDiskPutsTheDecodedImageInMemory() async {
        ImageStub.reset()
        let dirs = Directories()
        let url = coverURL("al-1")
        await dirs.makeCache().load(url)          // fills the regular cache
        let relaunched = dirs.makeCache()          // empty memory, like after a launch or a resume
        #expect(relaunched.image(for: url) == nil)

        let warmed = await relaunched.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize)
        #expect(warmed)
        #expect(relaunched.image(for: url) != nil)
        #expect(ImageStub.requestCount == 1)
    }

    @Test func bulkPreloadNeverGoesToTheNetwork() async {
        ImageStub.reset()
        let dirs = Directories()
        let cache = dirs.makeCache()
        let url = coverURL("al-2")

        let warmed = await cache.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize)
        #expect(!warmed)
        #expect(ImageStub.requestCount == 0)
        #expect(cache.image(for: url) == nil)
    }

    @Test func preloadCanFetchWhenAskedTo() async {
        ImageStub.reset()
        let cache = Directories().makeCache()
        let url = coverURL("al-3")

        #expect(await cache.preload(url, maxPixelSize: nil, allowNetwork: true))
        #expect(ImageStub.requestCount == 1)
        #expect(cache.image(for: url, maxPixelSize: nil) != nil)
    }

    @Test func preloadFindsTheImageInThePermanentCacheAfterARegularPurge() async {
        ImageStub.reset()
        let dirs = Directories()
        let url = coverURL("al-4")
        let first = dirs.makeCache()
        await first.load(url)
        await first.savePermanently(url)
        dirs.purgeRegular()

        let relaunched = dirs.makeCache()
        #expect(await relaunched.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize))
        #expect(ImageStub.requestCount == 1)
    }

    @Test func anImageAlreadyInMemoryIsNotLoadedAgain() async {
        ImageStub.reset()
        let dirs = Directories()
        let cache = dirs.makeCache()
        let url = coverURL("al-5")
        await cache.load(url)
        dirs.purgeRegular()                        // nothing left to read: only memory has it

        #expect(await cache.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize))
        #expect(ImageStub.requestCount == 1)
    }

    @Test func aPreloadAtOneTierDoesNotStandInForAnother() async {
        ImageStub.reset()
        let dirs = Directories()
        let url = coverURL("al-6")
        await dirs.makeCache().load(url)
        let cache = dirs.makeCache()

        #expect(await cache.preload(url, maxPixelSize: ImageCache.cardMaxPixelSize))
        #expect(cache.image(for: url, maxPixelSize: ImageCache.cardMaxPixelSize) != nil)
        #expect(cache.image(for: url, maxPixelSize: ImageCache.standardMaxPixelSize) == nil)
    }

    @Test func aSigningDifferenceDoesNotMakeAPreloadMiss() async {
        ImageStub.reset()
        let dirs = Directories()
        await dirs.makeCache().load(coverURL("al-7", token: "old"))
        let cache = dirs.makeCache()

        await cache.preload(coverURL("al-7", token: "old"), maxPixelSize: ImageCache.standardMaxPixelSize)
        #expect(cache.image(for: coverURL("al-7", token: "new")) != nil)
    }

    @Test func anUnpacedPreloadDecodesTheSameWay() async {
        ImageStub.reset()
        let dirs = Directories()
        let url = coverURL("al-9")
        await dirs.makeCache().load(url)
        let cache = dirs.makeCache()

        #expect(await cache.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize, paced: false))
        #expect(cache.image(for: url) != nil)
    }

    @Test func cancellingOneWaiterDoesNotCancelTheLoadAnotherNeeds() async {
        ImageStub.reset()
        let cache = Directories().makeCache()
        let url = coverURL("al-10")

        let leaving = Task { await cache.load(url) }
        let staying = Task { await cache.load(url) }
        leaving.cancel()
        #expect(await staying.value != nil)
        #expect(cache.image(for: url) != nil)
    }

    @Test func aLoadEveryoneGaveUpOnCanBeStartedAgain() async {
        ImageStub.reset()
        let cache = Directories().makeCache()
        let url = coverURL("al-11")

        let abandoned = Task { await cache.load(url) }
        abandoned.cancel()
        _ = await abandoned.value
        #expect(await cache.load(url) != nil)
        #expect(cache.image(for: url) != nil)
    }

    @Test func aCancelledPreloadDoesNothing() async {
        ImageStub.reset()
        let dirs = Directories()
        let url = coverURL("al-8")
        await dirs.makeCache().load(url)
        let cache = dirs.makeCache()

        let task = Task { () -> Bool in
            try? await Task.sleep(for: .seconds(5))
            return await cache.preload(url, maxPixelSize: ImageCache.standardMaxPixelSize)
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(cache.image(for: url) == nil)
    }
}

@Suite(.serialized)
struct ImageWarmerManifestTests {
    private func makeWarmer() -> ImageWarmer {
        let suite = "ImageWarmerTests-\(UUID().uuidString)"
        return ImageWarmer(defaults: UserDefaults(suiteName: suite)!, cache: Directories().makeCache(), scale: { 3 })
    }

    @Test func aRememberedFirstScreenfulComesBackInOrder() async {
        let warmer = makeWarmer()
        let requests = (0..<5).map { ArtworkRequest.albumCard("al-\($0)") }
        await warmer.remember(.albums, requests)
        #expect(await warmer.manifest(for: .albums) == requests)
        #expect(await warmer.manifest(for: .artists).isEmpty)
    }

    @Test func onlyTheFirstScreenfulIsKept() async {
        let warmer = makeWarmer()
        let requests = (0..<100).map { ArtworkRequest.songRow("s-\($0)", scale: 3) }
        await warmer.remember(.songs, requests)
        #expect(await warmer.manifest(for: .songs) == Array(requests.prefix(ImageWarmer.manifestLimit)))
    }

    @Test func requestsKeepTheTierTheViewsUse() {
        #expect(ArtworkRequest.albumCard("a").maxPixelSize == ImageCache.cardMaxPixelSize)
        #expect(ArtworkRequest.albumCard("a").size == nil)
        #expect(ArtworkRequest.albumRow("a", scale: 3).size == ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.album, scale: 3))
        #expect(ArtworkRequest.albumRow("a", scale: 3).maxPixelSize == ImageCache.standardMaxPixelSize)
        #expect(ArtworkRequest.albumHeader("a").maxPixelSize == ImageCache.standardMaxPixelSize)
        #expect(ArtworkRequest.artistRow("a", scale: 2).maxPixelSize == ImageCache.avatarMaxPixelSize)
        #expect(ArtworkRequest.artistHeader("a").maxPixelSize == ImageCache.cardMaxPixelSize)
        #expect(ArtworkRequest.nowPlaying("a").maxPixelSize == nil)
        #expect(ArtworkRequest.colorSampling("a").maxPixelSize == ImageCache.colorSamplingMaxPixelSize)
    }
}

@Suite(.serialized)
struct ArtistAlbumOrderingTests {
    private func album(_ id: String, _ name: String, year: Int, type: String? = nil) -> AlbumID3 {
        let json = """
        {"id":"\(id)","name":"\(name)","year":\(year),"songCount":1,"duration":1,"created":"2024-01-01T00:00:00Z"\(type.map { ",\"releaseTypes\":[\"\($0)\"]" } ?? "")}
        """
        return try! JSONDecoder().decode(AlbumID3.self, from: Data(json.utf8))
    }

    private var albums: [AlbumID3] {
        [album("a", "Beta", year: 2001), album("b", "Alpha", year: 2010), album("c", "Gamma", year: 1999)]
    }

    @Test func theFirstScreenfulFollowsTheSelectedSortFieldAndOrder() {
        func ids(_ settings: ArtistAlbumOrdering.Settings) -> [String] {
            ArtistAlbumOrdering.firstScreenful(of: albums, settings: settings, limit: 2).map(\.id.raw)
        }
        #expect(ids(.init(field: .title, ascending: true)) == ["b", "a"])
        #expect(ids(.init(field: .title, ascending: false)) == ["c", "a"])
        #expect(ids(.init(field: .year, ascending: true)) == ["c", "a"])
        #expect(ids(.init(field: .year, ascending: false)) == ["b", "a"])
    }

    @Test func separatedReleaseTypesListTheFirstCardsOfEachCarouselInFixedOrder() {
        let mixed = [
            album("s1", "Zed", year: 2020, type: "single"),
            album("l1", "Live", year: 2019, type: "album"),
            album("l2", "Another", year: 2018, type: "album"),
        ]
        let settings = ArtistAlbumOrdering.Settings(field: .title, ascending: true, separateReleaseTypes: true)
        let ids = ArtistAlbumOrdering.firstScreenful(of: mixed, settings: settings, limit: 12).map(\.id.raw)
        #expect(ids == ["l2", "l1", "s1"])
    }

    @Test func settingsAreReadFromTheSameDefaultsKeysTheViewStores() {
        let defaults = UserDefaults(suiteName: "ordering-\(UUID().uuidString)")!
        defaults.set("year", forKey: "artistAlbums.sortField")
        defaults.set("descending", forKey: "artistAlbums.sortOrder")
        defaults.set(true, forKey: "library.separateReleaseTypes")
        let settings = ArtistAlbumOrdering.Settings.stored(in: defaults)
        #expect(settings == .init(field: .year, ascending: false, groupVersions: false, separateReleaseTypes: true))
    }
}

@MainActor
struct ImageReadinessTests {
    @Test func aScreenWithNothingToWaitForIsReadyAtOnce() {
        let readiness = ImageReadiness()
        #expect(!readiness.isReady)
        readiness.require([])
        #expect(readiness.isReady)
    }
}

extension ImageCacheTests {
    @Test func theMemoizedKeyIsTheComputedKey() {
        let cache = Directories().makeCache()
        let url = coverURL("al-20", size: 192)
        let computed = cache.computeStableKey(for: url)
        #expect(cache.stableKey(for: url) == computed)
        #expect(cache.stableKey(for: url) == computed)            // from the memo
        #expect(cache.stableKey(for: coverURL("al-20", size: 192, token: "other")) == computed)
        #expect(cache.stableKey(for: coverURL("al-20")) != computed)
    }
}

/// An extension of `ImageCacheTests` for the same reason as the preload tests above: the stub's
/// request counter is shared.
extension ImageCacheTests {
    private func warmer(_ dirs: Directories) -> (ImageWarmer, ImageCache) {
        let cache = dirs.makeCache()
        let suite = "WarmAheadTests-\(UUID().uuidString)"
        return (ImageWarmer(defaults: UserDefaults(suiteName: suite)!, cache: cache, scale: { 3 }), cache)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func target(_ id: String) -> ImageWarmer.Target {
        .init(url: coverURL(id), maxPixelSize: ImageCache.standardMaxPixelSize)
    }

    @Test func eachSourceFinishesItsOwnQueue() async {
        ImageStub.reset()
        let dirs = Directories()
        for id in ["a1", "a2", "b1", "b2"] { await dirs.makeCache().load(coverURL(id)) }
        let (warmer, cache) = warmer(dirs)

        await warmer.warmAhead(targets: [target("a1"), target("a2")], source: "A")
        await warmer.warmAhead(targets: [target("b1"), target("b2")], source: "B")
        let done = await waitUntil {
            ["a1", "a2", "b1", "b2"].allSatisfy { cache.image(for: coverURL($0)) != nil }
        }
        #expect(done)
    }

    @Test func aNewCallFromTheSameSourceKeepsTheWorkerGoing() async {
        ImageStub.reset()
        let dirs = Directories()
        for id in ["c1", "c2", "c3", "c4"] { await dirs.makeCache().load(coverURL(id)) }
        let (warmer, cache) = warmer(dirs)

        await warmer.warmAhead(targets: [target("c1"), target("c2"), target("c3")], source: "S")
        // The next card appears: the queue moves on, nothing already under way is cancelled.
        await warmer.warmAhead(targets: [target("c2"), target("c3"), target("c4")], source: "S")
        let done = await waitUntil {
            ["c2", "c3", "c4"].allSatisfy { cache.image(for: coverURL($0)) != nil }
        }
        #expect(done)
    }

    @Test func aSourceCanBeWarmedAgainAfterItsQueueRanDry() async {
        ImageStub.reset()
        let dirs = Directories()
        for id in ["d1", "d2"] { await dirs.makeCache().load(coverURL(id)) }
        let (warmer, cache) = warmer(dirs)

        await warmer.warmAhead(targets: [target("d1")], source: "S")
        #expect(await waitUntil { cache.image(for: coverURL("d1")) != nil })
        await warmer.warmAhead(targets: [target("d2")], source: "S")
        #expect(await waitUntil { cache.image(for: coverURL("d2")) != nil })
    }
}

@MainActor
struct DownloadProgressStoreTests {
    @Test func progressTicksDoNotPublishFromTheDownloadStore() {
        var downloadStorePublishes = 0
        var progressPublishes = 0
        let a = DownloadStore.shared.objectWillChange.sink { downloadStorePublishes += 1 }
        let b = DownloadProgressStore.shared.objectWillChange.sink { progressPublishes += 1 }
        defer { DownloadProgressStore.shared.set([:]); a.cancel(); b.cancel() }

        DownloadProgressStore.shared.set(["song": 0.25])
        DownloadProgressStore.shared.set(["song": 0.5])
        DownloadProgressStore.shared.set(["song": 0.5])           // unchanged: not published

        #expect(downloadStorePublishes == 0)
        #expect(progressPublishes == 2)
    }
}
