import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Cache for downloaded images, in three tiers:
///
/// 1. **Memory** — an `NSCache` of decoded bitmaps.
/// 2. **The regular cache** — `Caches/SubsonicImageCache/`. Every image the app shows lives here,
///    and this is the only place `load(_:)` ever looks first. iOS may purge it under storage
///    pressure with no notice.
/// 3. **The permanent cache** — `Application Support/DownloadedArtwork/`, which iOS never purges.
///    Written only by `savePermanently(_:)` — for the artwork of everything that has downloaded
///    music (see `DownloadedArtwork`) — never by browsing, so it doesn't grow unboundedly.
///
/// When an image is missing from the regular cache (never fetched, or purged) it's loaded from the
/// permanent cache if that has it, otherwise from the server — and either way written back to the
/// regular cache, so the next load is a regular-cache hit again.
///
/// `SubsonicClient.url(for:_:)` signs every request with a freshly-randomized salt/token (see
/// its token-auth scheme), so calling `coverArtURL(forId:)` twice for the *same* album returns
/// two *different* URLs. Caching by the raw URL would essentially never hit. Instead,
/// everything here is keyed by a stable form of the URL with the volatile auth query items
/// (`u`, `t`, `s`, `v`, `c`, `f`) stripped out, leaving just what actually identifies the
/// image (host, path, and whatever's left in the query — `id`, `size`, ...).
///
/// The bytes on disk are always whatever the server sent (original size when no `size` param
/// was requested). What's capped is the *decoded in-memory bitmap*: by default an image is
/// decoded down to `standardMaxPixelSize` on its longest side, since nothing in a list, card,
/// carousel or detail header is displayed anywhere near original resolution, and decoding (and
/// holding) a 3000² cover for a 160pt card is what made opening a screen full of artwork spike
/// every core. Pass `maxPixelSize: nil` to get the full-resolution bitmap (Now Playing).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// The size, in pixels, images are decoded to by default — the album/playlist headers'
    /// tier. The largest thing that shows a cover apart from Now Playing is the album header at
    /// 270pt (≈810px at 3x), so this leaves headroom without any visible softness.
    static let standardMaxPixelSize = 900
    /// Cards and grid cells (~170pt wide, ≈510px at 3x). Decoding these at the header tier would
    /// mean up to 3x the pixels for nothing, dozens of times over on a screen full of covers.
    static let cardMaxPixelSize = 512
    /// Small round avatars (a 48pt artist row is 144px at 3x).
    static let avatarMaxPixelSize = 256
    /// For sampling dominant colours only (Now Playing background): far smaller than anything shown.
    static let colorSamplingMaxPixelSize = 96

    /// The point size of the artwork in each kind of list row. Rows request a server-downscaled
    /// thumbnail of that size (`coverArtURL(forId:size:)`), and the permanent cache saves exactly
    /// those thumbnails for downloaded content — so both read their sizes from here, or a
    /// mismatch would quietly turn every saved thumbnail into a miss.
    enum RowArtwork {
        static let song: CGFloat = 44
        static let album: CGFloat = 64
        static let playlist: CGFloat = 64
        static let artist: CGFloat = 48

        /// The `size` parameter to request a row thumbnail with, for a screen of this scale.
        static func pixels(_ points: CGFloat, scale: CGFloat) -> Int {
            Int(points * scale)
        }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let session: URLSession
    /// The regular cache (`Caches/`) — see the type's doc comment.
    private let regularDirectory: URL?
    /// The permanent cache (`Application Support/`) — see the type's doc comment.
    private let permanentDirectory: URL?

    private let lock = NSLock()
    /// Requests in flight, keyed by the same stable key plus size tier as the memory cache, so a
    /// view's own load (or several views wanting the same image at once) share one fetch instead
    /// of racing duplicate ones.
    private var inFlightTasks: [String: InFlight] = [:]

    /// One shared load, and how many callers are still waiting for it. When the last one leaves
    /// (its view scrolled away, its screen was popped) the load is cancelled — see `load`.
    private final class InFlight: @unchecked Sendable {
        let task: Task<UIImage?, Never>
        var waiters = 1
        init(task: Task<UIImage?, Never>) { self.task = task }
    }

    /// Makes sure one caller only leaves an `InFlight` once, whether it finished or was cancelled.
    private final class Departure: @unchecked Sendable {
        private let lock = NSLock()
        private var left = false
        func claim() -> Bool { lock.withLock { defer { left = true }; return !left } }
    }

    /// Decodes run one at a time, each followed by `decodeCooldown` of idle time before the next
    /// may start. Decoding is the CPU-heavy part of loading an image; without a bound, opening a
    /// screen with a dozen covers starts a dozen decodes at the same instant, one per core, which
    /// is the multi-hundred-percent spike this exists to prevent. Serializing caps the burst at
    /// one core, and the cooldown (a decode is ~10-100ms) keeps that one core from being pinned
    /// solid while a queue drains. Only cold decodes pay this: anything already in memory is
    /// returned before reaching the gate. Raise `limit` / lower the cooldown to trade CPU for
    /// artwork appearing sooner.
    private let decodeGate = AsyncLimiter(limit: 2)
    private static let decodeCooldown: Duration = .milliseconds(10)
    /// Same idea for `prefetchOriginalData`'s downloads — not CPU-heavy, but a screen full of
    /// rows shouldn't open dozens of simultaneous connections either.
    private let prefetchGate = AsyncLimiter(limit: 4)
    /// `preload`'s own gate: warm-ups queue up here one at a time, so at most one of them is ever
    /// waiting at the `decodeGate` — an on-screen cell's decode is never stuck behind a backlog of
    /// them — and the pause after each keeps a long warm-up from pinning a core.
    private let warmGate = AsyncLimiter(limit: 1)
    private static let warmCooldown: Duration = .milliseconds(40)

    init(
        regularDirectory: URL? = ImageCache.defaultRegularDirectory(),
        permanentDirectory: URL? = ImageCache.defaultPermanentDirectory(),
        session: URLSession = .shared
    ) {
        memory.totalCostLimit = 120 * 1024 * 1024
        self.regularDirectory = regularDirectory
        self.permanentDirectory = permanentDirectory
        self.session = session
    }

    private static func defaultRegularDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("SubsonicImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func defaultPermanentDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var dir = support.appendingPathComponent("DownloadedArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// In-memory-only lookup, synchronous — used by `CachedAsyncImage` at init so a warm
    /// in-memory hit can render on the very first frame. Doesn't consult disk; use `load(_:)`
    /// for the full memory → disk → network lookup.
    func image(for url: URL, maxPixelSize: Int? = ImageCache.standardMaxPixelSize) -> UIImage? {
        memory.object(forKey: memoryKey(stableKey(for: url), maxPixelSize: maxPixelSize))
    }

    /// Returns the cached image for `url` if present (memory, then the regular cache), otherwise
    /// loads it from the permanent cache or the server — see `originalData(for:key:)` — and
    /// caches the result.
    @discardableResult
    func load(_ url: URL, maxPixelSize: Int? = ImageCache.standardMaxPixelSize) async -> UIImage? {
        let key = stableKey(for: url)
        let memKey = memoryKey(key, maxPixelSize: maxPixelSize)
        if let cached = memory.object(forKey: memKey) { return cached }

        let entry = joinOrStart(memKey: memKey, key: key, url: url, maxPixelSize: maxPixelSize)
        let departure = Departure()
        // A caller that goes away — a row scrolled off screen, a popped screen — stops waiting;
        // once nobody is left waiting the load itself is cancelled, so a fast scroll doesn't leave
        // a queue of decodes for images that are no longer visible ahead of the ones that are.
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            leave(entry, memKey: memKey as String, departure)
        }
        leave(entry, memKey: memKey as String, departure)
        return result
    }

    /// Returns the in-flight load for `memKey` — counting the caller among its waiters — or
    /// creates and registers a new one, atomically, so two concurrent callers for the same key
    /// can't both decide to start their own fetch. Synchronous (unlike `load` itself) so the
    /// locking stays a plain, provably-safe critical section instead of straddling `async`
    /// suspension points.
    private func joinOrStart(memKey: NSString, key: String, url: URL, maxPixelSize: Int?) -> InFlight {
        lock.withLock {
            if let existing = inFlightTasks[memKey as String] {
                existing.waiters += 1
                return existing
            }
            let task = Task<UIImage?, Never> { [weak self] in
                await self?.fetch(url, key: key, memKey: memKey, maxPixelSize: maxPixelSize)
            }
            let entry = InFlight(task: task)
            inFlightTasks[memKey as String] = entry
            return entry
        }
    }

    /// A caller stops waiting for `entry`. The last one out unregisters it (so a later request
    /// starts fresh rather than joining a cancelled load) and cancels it.
    private func leave(_ entry: InFlight, memKey: String, _ departure: Departure) {
        guard departure.claim() else { return }
        let isLast = lock.withLock { () -> Bool in
            entry.waiters -= 1
            guard entry.waiters == 0 else { return false }
            if inFlightTasks[memKey] === entry { inFlightTasks[memKey] = nil }
            return true
        }
        if isLast { entry.task.cancel() }
    }

    private func fetch(_ url: URL, key: String, memKey: NSString, maxPixelSize: Int?) async -> UIImage? {
        // Network and disk reads happen outside the decode gate: they aren't CPU-bound, and
        // gating them would just let a slow download hold up unrelated decodes.
        guard let data = await originalData(for: url, key: key) else { return nil }

        await decodeGate.acquire()
        // Cancelled while waiting its turn (nobody wants this image any more): give the slot
        // straight back, with no decode and no cooldown.
        if Task.isCancelled {
            await decodeGate.release()
            return nil
        }
        let image = decodedImage(from: data, maxPixelSize: maxPixelSize)
        if let image { store(image, forKey: memKey) }
        // The cooldown runs in its own task, holding the slot, so this image is handed back to
        // its caller right now — only the *next* decode waits out the pause.
        let gate = decodeGate
        Task {
            try? await Task.sleep(for: Self.decodeCooldown)
            await gate.release()
        }

        return image
    }

    /// The original bytes for `url`: from the regular cache if it has them; otherwise — it was
    /// never fetched, or iOS purged it — from the permanent cache, then the server. Whichever of
    /// those supplies them, they're written back to the regular cache, so every later load is a
    /// regular-cache hit.
    private func originalData(for url: URL, key: String) async -> Data? {
        if let data = readRegular(key) { return data }
        if let data = readPermanent(key) {
            writeRegular(data, forKey: key)
            return data
        }
        guard let data = await downloadImageData(url) else { return nil }
        writeRegular(data, forKey: key)
        return data
    }

    /// Makes sure `url`'s original bytes are in the regular cache, without decoding anything —
    /// for warming the cache ahead of a screen that will want the full image (e.g. so opening an
    /// album from a list doesn't wait on the network), without paying for a decode of an image
    /// that may never be shown at that size. Cancellable: call it from a `.task`, which cancels it
    /// when the row scrolls away.
    func prefetchOriginalData(_ url: URL?) async {
        guard let url else { return }
        let key = stableKey(for: url)
        if fileExists(regularURL(forKey: key)) { return }
        if let data = readPermanent(key) {
            writeRegular(data, forKey: key)
            return
        }

        await prefetchGate.acquire()
        defer { Task { await prefetchGate.release() } }
        guard !Task.isCancelled else { return }
        guard let data = await downloadImageData(url) else { return }
        writeRegular(data, forKey: key)
    }

    /// Whether `request`'s decoded image is already in memory.
    func isCached(_ request: ArtworkRequest) -> Bool {
        guard let url = request.url else { return false }
        return image(for: url, maxPixelSize: request.maxPixelSize) != nil
    }

    /// Decodes `request`'s image into memory ahead of the screen that will show it, so that screen
    /// opens with the image already on its first frame (`CachedAsyncImage` reads memory at init)
    /// instead of a placeholder that fills in after a disk read and a decode.
    ///
    /// Warm-ups go through their own gate — one at a time, with a longer pause after each — and
    /// then through the ordinary `load`, so they never start a burst of decodes, and a view that
    /// wants the same image meanwhile just joins the in-flight load. Cancellable (call it from a
    /// task that's cancelled when the screen or row goes away). Without `allowNetwork` an image
    /// that isn't already on disk is skipped: bulk warming must never fan out into downloads.
    /// `paced: false` skips the warm-up gate and its pause, for a screen that's already open and
    /// waiting on these images (it still goes through the decode gate, one at a time).
    /// Returns whether the image is in memory afterwards.
    @discardableResult
    func preload(_ request: ArtworkRequest, allowNetwork: Bool = false, paced: Bool = true) async -> Bool {
        guard let url = request.url else { return false }
        return await preload(url, maxPixelSize: request.maxPixelSize, allowNetwork: allowNetwork, paced: paced)
    }

    /// `preload(_:allowNetwork:paced:)` for a URL that's already in hand (Now Playing's `artworkURL`).
    @discardableResult
    func preload(_ url: URL, maxPixelSize: Int?, allowNetwork: Bool = false, paced: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        let key = stableKey(for: url)
        let memKey = memoryKey(key, maxPixelSize: maxPixelSize)
        if memory.object(forKey: memKey) != nil { return true }
        if !allowNetwork, !fileExists(regularURL(forKey: key)), !fileExists(permanentURL(forKey: key)) {
            return false
        }
        guard paced else { return await load(url, maxPixelSize: maxPixelSize) != nil }

        await warmGate.acquire()
        let gate = warmGate
        defer {
            Task {
                try? await Task.sleep(for: Self.warmCooldown)
                await gate.release()
            }
        }
        guard !Task.isCancelled else { return false }
        if memory.object(forKey: memKey) != nil { return true }
        return await load(url, maxPixelSize: maxPixelSize) != nil
    }

    /// Makes sure `url`'s image is saved in *both* the regular cache and the permanent one,
    /// fetching it from the server only if neither has it — whichever one has it supplies the
    /// other. For the artwork of downloaded content, so it's still available offline even after
    /// iOS purges the regular cache. Returns whether the image ended up in both — `false` only on
    /// a genuine failure (offline, deleted on the server, ...). Only stores bytes; it doesn't
    /// decode anything into the in-memory cache, since nothing needs it warm.
    @discardableResult
    func savePermanently(_ url: URL) async -> Bool {
        let key = stableKey(for: url)
        let inRegular = fileExists(regularURL(forKey: key))
        let inPermanent = fileExists(permanentURL(forKey: key))
        if inRegular && inPermanent { return true }

        if inRegular, let data = readRegular(key) {
            writeToPermanent(data, forKey: key)
            return fileExists(permanentURL(forKey: key))
        }
        if inPermanent, let data = readPermanent(key) {
            writeRegular(data, forKey: key)
            return fileExists(regularURL(forKey: key))
        }
        guard let data = await downloadImageData(url) else { return false }
        writeRegular(data, forKey: key)
        writeToPermanent(data, forKey: key)
        return true
    }

    /// Drops `url`'s image from every tier — each in-memory size tier, the regular cache and the
    /// permanent one — so the next load refetches it from the server. Keyed the same stable way
    /// as everything else here, so any freshly-signed URL for the same image works.
    func remove(_ url: URL) {
        let key = stableKey(for: url)
        let tiers: [Int?] = [nil, Self.standardMaxPixelSize, Self.cardMaxPixelSize, Self.avatarMaxPixelSize, Self.colorSamplingMaxPixelSize]
        for tier in tiers {
            memory.removeObject(forKey: memoryKey(key, maxPixelSize: tier))
        }
        if let fileURL = regularURL(forKey: key) { try? fileManager.removeItem(at: fileURL) }
        if let fileURL = permanentURL(forKey: key) { try? fileManager.removeItem(at: fileURL) }
    }

    /// Drops every cached entry from memory and the regular cache, e.g. when switching to a
    /// different server. The permanent cache is left alone: it's keyed by the server's host, so
    /// it can't be mistaken for another server's artwork, and it's what keeps downloaded content's
    /// artwork available offline.
    func invalidateAll() {
        memory.removeAllObjects()
        guard let regularDirectory else { return }
        try? fileManager.removeItem(at: regularDirectory)
        try? fileManager.createDirectory(at: regularDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Network

    /// `url`'s bytes, but only if the server answered successfully *and* what came back is
    /// actually an image. Without the second check, an error body (Subsonic reports a missing
    /// cover as a JSON error) would be written to disk — and, for downloaded content, to the
    /// permanent cache — as if it were the artwork, and never retried.
    private func downloadImageData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard Self.isImage(data) else { return nil }
        return data
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: - Memory layer

    /// Stable key plus the size tier — an image decoded down to 900px and the same image at
    /// original size are different bitmaps, and must not be handed out for each other.
    private func memoryKey(_ key: String, maxPixelSize: Int?) -> NSString {
        (maxPixelSize.map { "\(key)@\($0)" } ?? key) as NSString
    }

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key, cost: cost)
    }

    // MARK: - Stable cache key

    func stableKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let volatileParams: Set<String> = ["u", "t", "s", "v", "c", "f"]
        components.queryItems = components.queryItems?
            .filter { !volatileParams.contains($0.name) }
            .sorted { $0.name < $1.name }
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Disk tiers

    private func regularURL(forKey key: String) -> URL? {
        regularDirectory.map { $0.appendingPathComponent(SubsonicClient.md5Hex(key)).appendingPathExtension("img") }
    }

    private func permanentURL(forKey key: String) -> URL? {
        permanentDirectory.map { $0.appendingPathComponent(SubsonicClient.md5Hex(key)).appendingPathExtension("img") }
    }

    private func fileExists(_ url: URL?) -> Bool {
        url.map { fileManager.fileExists(atPath: $0.path) } ?? false
    }

    private func readRegular(_ key: String) -> Data? {
        regularURL(forKey: key).flatMap { try? Data(contentsOf: $0) }
    }

    private func readPermanent(_ key: String) -> Data? {
        permanentURL(forKey: key).flatMap { try? Data(contentsOf: $0) }
    }

    private func writeRegular(_ data: Data, forKey key: String) {
        guard let fileURL = regularURL(forKey: key) else { return }
        write(data, to: fileURL)
    }

    private func writeToPermanent(_ data: Data, forKey key: String) {
        guard let fileURL = permanentURL(forKey: key) else { return }
        write(data, to: fileURL)
    }

    /// Recreates the directory first if it's gone — iOS can purge `Caches/` wholesale, folder
    /// included, while the app is running, and the images that purge took out are exactly the ones
    /// that need writing back.
    private func write(_ data: Data, to fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Decoding

    /// Decodes `data` into a plain, fully-decoded device-RGB bitmap, right away, off the main
    /// thread — rather than handing back a `UIImage` that lazily decodes (via ImageIO's newer
    /// block-based decoder) whenever UIKit/SwiftUI first draws it. That lazy path has a real,
    /// filed Apple bug (rdar://143602439, logged as "kCGImageBlockFormatBGRx8 is called for
    /// 24-bpp (8-bpc) image") that can hang the *main* thread mid-decode for certain JPEGs —
    /// which read as a random app freeze, since it only fires whenever some particular image
    /// happens to first scroll/switch into view. Forcing the real decode here means the image
    /// handed to SwiftUI is already a plain bitmap with nothing left to lazily (and buggily)
    /// decode on the main thread.
    ///
    /// With a `maxPixelSize`, an oversized image is decoded at reduced size instead of decoded
    /// whole and shrunk afterwards — measured, cold-opening a screen of ~12 covers, the full
    /// decode plus the resample-and-convert passes after it were the largest app-controlled CPU
    /// cost. For a JPEG (nearly every cover) that's ImageIO's DCT sub-sampling: it decodes at
    /// 1/2, 1/4 or 1/8 scale directly, skipping most of the IDCT work and needing no resample at
    /// all. The factor is the largest power of two that still leaves the result at least
    /// `maxPixelSize` on its longest side (so it lands between 1x and 2x the target — SwiftUI
    /// scales that down on the GPU). Other formats far over the cap take ImageIO's thumbnail
    /// path (which does resample); anything at or near the cap, and `maxPixelSize == nil`, takes
    /// the plain full-size path.
    private func decodedImage(from data: Data, maxPixelSize: Int?) -> UIImage? {
        if let maxPixelSize, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let longest = max(width, height)

            if longest > maxPixelSize, let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .jpeg) == true {
                var factor = 1
                while factor < 8, longest / (factor * 2) >= maxPixelSize { factor *= 2 }
                if factor > 1 {
                    let options: [CFString: Any] = [
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceSubsampleFactor: factor,
                    ]
                    if let reduced = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                        return normalizedBitmap(from: reduced, scale: 1, orientation: .up)
                    }
                }
            } else if Double(longest) > Double(maxPixelSize) * Self.downsampleThreshold {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ]
                if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return normalizedBitmap(from: thumbnail, scale: 1, orientation: .up)
                }
            }
        }
        guard let source = UIImage(data: data), let cgImage = source.cgImage else { return nil }
        return normalizedBitmap(from: cgImage, scale: source.scale, orientation: .up) ?? source
    }

    /// How many times over the cap an image has to be before it's worth downsampling — see
    /// `decodedImage(from:maxPixelSize:)`.
    private static let downsampleThreshold = 1.5

    /// Redraws `cgImage` into a plain device-RGB, premultiplied-alpha bitmap — the workaround
    /// described on `decodedImage(from:maxPixelSize:)`.
    private func normalizedBitmap(from cgImage: CGImage, scale: CGFloat, orientation: UIImage.Orientation) -> UIImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else { return nil }
        return UIImage(cgImage: normalized, scale: scale, orientation: orientation)
    }
}

/// A minimal async counting semaphore: at most `limit` callers between `acquire()` and
/// `release()` at once; the rest suspend in FIFO order until a slot frees up.
private actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A drop-in replacement for `AsyncImage(url:content:placeholder:)` that checks `ImageCache`
/// first — synchronously, at init — so a cache hit renders on the very first frame instead of
/// flashing the placeholder while a redundant fetch happens.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    /// See `ImageCache.load(_:maxPixelSize:)` — the standard cap unless a caller (Now Playing)
    /// needs the full-resolution bitmap.
    private let maxPixelSize: Int?
    /// A smaller tier to show *immediately* if `maxPixelSize`'s isn't decoded yet but this one is
    /// — e.g. an album header opened from a card, whose (smaller) card image is already in
    /// memory: it stands in during the zoom transition instead of a placeholder, then the
    /// full-tier image replaces it once decoded.
    private let fallbackMaxPixelSize: Int?
    /// How long to wait before starting to load an image that isn't already in memory. The load
    /// runs in this view's `.task`, so a cell that scrolls away (or a screen that's popped) during
    /// the wait cancels it and never pays for the decode — and covers a screen opens with don't
    /// all start decoding on top of the navigation push's own main-thread burst.
    private let loadDelay: Duration
    /// Fires once per `url` when a `UIImage` is obtained for it (a cache hit or a fresh load) —
    /// lets a caller that needs the raw bitmap itself (e.g. to sample its average color) get it
    /// directly, instead of re-deriving one from the wrapped `Image` via `ImageRenderer`, which
    /// would mean redundantly re-rendering an image that's already been decoded.
    private let onLoad: ((UIImage) -> Void)?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    /// The url `uiImage` was actually loaded for, so a changed `url` on an otherwise-identical
    /// view (e.g. the mini player swapping tracks) is recognized as needing a reload — `@State`
    /// survives across re-inits of this struct, so checking `uiImage == nil` alone would leave
    /// the previous track's artwork on screen forever once one image had loaded.
    @State private var loadedURL: URL?
    /// The url `onLoad` has already fired for. This struct is re-initialized on every parent
    /// re-render, and `onLoad` used to fire from `init` on a cache hit — so a parent that
    /// re-rendered a few times right after opening (downloads publishing, its own `@State`
    /// loading in) re-ran whatever expensive thing `onLoad` does (color extraction) every time.
    @State private var notifiedURL: URL?

    init(
        url: URL?,
        maxPixelSize: Int? = ImageCache.standardMaxPixelSize,
        fallbackMaxPixelSize: Int? = nil,
        loadDelay: Duration = .zero,
        onLoad: ((UIImage) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.fallbackMaxPixelSize = fallbackMaxPixelSize
        self.loadDelay = loadDelay
        self.onLoad = onLoad
        self.content = content
        self.placeholder = placeholder
        let cached = url.flatMap { ImageCache.shared.image(for: $0, maxPixelSize: maxPixelSize) }
        let standIn = cached ?? fallbackMaxPixelSize.flatMap { tier in
            url.flatMap { ImageCache.shared.image(for: $0, maxPixelSize: tier) }
        }
        _uiImage = State(initialValue: standIn)
        _loadedURL = State(initialValue: cached != nil ? url : nil)
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            uiImage = nil
            loadedURL = nil
            return
        }
        if loadedURL == url {
            // Already showing this url's image (a cache hit at init) — nothing to load, but
            // `onLoad` hasn't fired for it yet.
            notifyLoaded()
            return
        }
        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            uiImage = cached
            loadedURL = url
            notifyLoaded()
            return
        }
        // Showing a smaller stand-in already (see `fallbackMaxPixelSize`): it's good enough for
        // `onLoad`'s purposes (e.g. an average color), so don't make that wait for the full decode.
        notifyLoaded()
        if loadDelay > .zero {
            try? await Task.sleep(for: loadDelay)
            if Task.isCancelled { return }
        }
        guard let image = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize) else { return }
        await MainActor.run {
            if self.url == url {
                uiImage = image
                loadedURL = url
                notifyLoaded()
            }
        }
    }

    private func notifyLoaded() {
        guard let uiImage, notifiedURL != url else { return }
        notifiedURL = url
        onLoad?(uiImage)
    }
}
