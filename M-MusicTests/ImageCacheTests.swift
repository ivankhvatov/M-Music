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
