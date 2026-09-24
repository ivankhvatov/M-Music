import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Cache for downloaded images, backed by both an in-memory `NSCache` and disk
/// (`Caches/SubsonicImageCache/`), so artwork already fetched once — this session or a
/// previous one — is available without a network round trip.
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

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let directory: URL?
    /// A second, durable disk tier under `Application Support/DownloadedArtwork/` — unlike
    /// `directory` (`Caches/`), iOS never purges this under storage pressure with no notice.
    /// Populated only by `precacheDurably(_:)` (called when a song finishes downloading), never
    /// by the normal `load(_:)` path, so browsing alone doesn't grow it unboundedly.
    private let durableDirectory: URL?

    private let lock = NSLock()
    /// Requests in flight, keyed by the same stable key plus size tier as the memory cache, so a
    /// view's own load (or several views wanting the same image at once) share one fetch instead
    /// of racing duplicate ones.
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    /// Decodes run one at a time, each followed by `decodeCooldown` of idle time before the next
    /// may start. Decoding is the CPU-heavy part of loading an image; without a bound, opening a
    /// screen with a dozen covers starts a dozen decodes at the same instant, one per core, which
    /// is the multi-hundred-percent spike this exists to prevent. Serializing caps the burst at
    /// one core, and the cooldown (a decode is ~10-100ms) keeps that one core from being pinned
    /// solid while a queue drains. Only cold decodes pay this: anything already in memory is
    /// returned before reaching the gate. Raise `limit` / lower the cooldown to trade CPU for
    /// artwork appearing sooner.
    private let decodeGate = AsyncLimiter(limit: 1)
    private static let decodeCooldown: Duration = .milliseconds(20)
    /// Same idea for `prefetchOriginalData`'s downloads — not CPU-heavy, but a screen full of
    /// rows shouldn't open dozens of simultaneous connections either.
    private let prefetchGate = AsyncLimiter(limit: 4)

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("SubsonicImageCache", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
        } else {
            directory = nil
        }
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            var dir = support.appendingPathComponent("DownloadedArtwork", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            durableDirectory = dir
        } else {
            durableDirectory = nil
        }
    }

    /// In-memory-only lookup, synchronous — used by `CachedAsyncImage` at init so a warm
    /// in-memory hit can render on the very first frame. Doesn't consult disk; use `load(_:)`
    /// for the full memory → disk → network lookup.
    func image(for url: URL, maxPixelSize: Int? = ImageCache.standardMaxPixelSize) -> UIImage? {
        memory.object(forKey: memoryKey(stableKey(for: url), maxPixelSize: maxPixelSize))
    }

    /// Returns the cached image for `url` if present (memory, then disk), otherwise downloads
    /// it and caches the result both ways.
    @discardableResult
    func load(_ url: URL, maxPixelSize: Int? = ImageCache.standardMaxPixelSize) async -> UIImage? {
        let key = stableKey(for: url)
        let memKey = memoryKey(key, maxPixelSize: maxPixelSize)
        if let cached = memory.object(forKey: memKey) { return cached }

        let (task, isNew) = inFlightTaskOrRegister(memKey: memKey, key: key, url: url, maxPixelSize: maxPixelSize)
        let result = await task.value
        if isNew {
            clearInFlightTask(forKey: memKey as String)
        }
        return result
    }

    /// Returns the in-flight task for `memKey` if one's already running, otherwise creates,
    /// registers, and returns a new one — atomically, so two concurrent callers for the same
    /// key can't both decide to start their own fetch. Synchronous (unlike `load` itself) so
    /// the locking stays a plain, provably-safe critical section instead of straddling
    /// `async` suspension points.
    private func inFlightTaskOrRegister(
        memKey: NSString, key: String, url: URL, maxPixelSize: Int?
    ) -> (task: Task<UIImage?, Never>, isNew: Bool) {
        lock.withLock {
            if let existing = inFlightTasks[memKey as String] {
                return (existing, false)
            }
            let task = Task<UIImage?, Never> { [weak self] in
                await self?.fetch(url, key: key, memKey: memKey, maxPixelSize: maxPixelSize)
            }
            inFlightTasks[memKey as String] = task
            return (task, true)
        }
    }

    private func clearInFlightTask(forKey key: String) {
        lock.withLock { inFlightTasks[key] = nil }
    }

    private func fetch(_ url: URL, key: String, memKey: NSString, maxPixelSize: Int?) async -> UIImage? {
        // Network and disk reads happen outside the decode gate: they aren't CPU-bound, and
        // gating them would just let a slow download hold up unrelated decodes.
        guard let data = await originalData(for: url, key: key) else { return nil }

        await decodeGate.acquire()
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

    /// The original bytes for `url` from the first tier that has them (Caches disk, then the
    /// durable directory), otherwise the network — which also writes them to the Caches disk tier.
    private func originalData(for url: URL, key: String) async -> Data? {
        if let fileURL = diskURL(forKey: key), let data = try? Data(contentsOf: fileURL) {
            return data
        }
        if let fileURL = durableURL(forKey: key), let data = try? Data(contentsOf: fileURL) {
            return data
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        writeToDisk(data, forKey: key)
        return data
    }

    /// Downloads `url`'s original bytes to the disk cache if they aren't there already, without
    /// decoding anything — for warming the cache ahead of a screen that will want the full image
    /// (e.g. so opening an album from a list doesn't wait on the network), without paying for a
    /// decode of an image that may never be shown at that size. Cancellable: call it from a
    /// `.task`, which cancels it when the row scrolls away.
    func prefetchOriginalData(_ url: URL?) async {
        guard let url else { return }
        let key = stableKey(for: url)
        if let fileURL = diskURL(forKey: key), fileManager.fileExists(atPath: fileURL.path) { return }
        if let fileURL = durableURL(forKey: key), fileManager.fileExists(atPath: fileURL.path) { return }

        await prefetchGate.acquire()
        defer { Task { await prefetchGate.release() } }
        guard !Task.isCancelled else { return }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return }
        writeToDisk(data, forKey: key)
    }

    /// Fetches `url`'s image if not already cached anywhere, and stores it durably under
    /// Application Support (survives `Caches/` eviction) in addition to the normal Caches-disk
    /// tier. For downloaded songs' artwork, so it's still available offline even under storage
    /// pressure. Returns whether the image ended up durably cached — already was, or was just
    /// fetched and stored — `false` only on a genuine failure (offline, deleted on server, ...).
    /// Only stores bytes; it doesn't decode anything into the in-memory cache, since nothing
    /// needs it warm right when a download finishes.
    @discardableResult
    func precacheDurably(_ url: URL) async -> Bool {
        let key = stableKey(for: url)
        if let durableURL = durableURL(forKey: key), fileManager.fileExists(atPath: durableURL.path) {
            return true
        }
        if let cachesURL = diskURL(forKey: key), let data = try? Data(contentsOf: cachesURL) {
            writeDurably(data, forKey: key)
            return true
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return false }
        writeToDisk(data, forKey: key)
        writeDurably(data, forKey: key)
        return true
    }

    /// Drops every cached entry (memory and disk), e.g. when switching to a different server.
    func invalidateAll() {
        memory.removeAllObjects()
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func stableKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let volatileParams: Set<String> = ["u", "t", "s", "v", "c", "f"]
        components.queryItems = components.queryItems?
            .filter { !volatileParams.contains($0.name) }
            .sorted { $0.name < $1.name }
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Disk layer

    private func diskURL(forKey key: String) -> URL? {
        guard let directory else { return nil }
        return directory.appendingPathComponent(SubsonicClient.md5Hex(key)).appendingPathExtension("img")
    }

    private func writeToDisk(_ data: Data, forKey key: String) {
        guard let fileURL = diskURL(forKey: key) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Durable disk layer (Application Support, survives Caches/ eviction)

    private func durableURL(forKey key: String) -> URL? {
        guard let durableDirectory else { return nil }
        return durableDirectory.appendingPathComponent(SubsonicClient.md5Hex(key)).appendingPathExtension("img")
    }

    private func writeDurably(_ data: Data, forKey key: String) {
        guard let fileURL = durableURL(forKey: key) else { return }
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
