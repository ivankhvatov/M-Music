import SwiftUI

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
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let directory: URL?
    /// A second, durable disk tier under `Application Support/DownloadedArtwork/` — unlike
    /// `directory` (`Caches/`), iOS never purges this under storage pressure with no notice.
    /// Populated only by `precacheDurably(_:)` (called when a song finishes downloading), never
    /// by the normal `load(_:)` path, so browsing alone doesn't grow it unboundedly.
    private let durableDirectory: URL?

    private let lock = NSLock()
    /// Requests in flight, keyed the same stable way, so a prefetch and a view's own load (or
    /// several views wanting the same image at once) share one fetch instead of racing
    /// duplicate ones.
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    init() {
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
    func image(for url: URL) -> UIImage? {
        memory.object(forKey: stableKey(for: url) as NSString)
    }

    /// Returns the cached image for `url` if present (memory, then disk), otherwise downloads
    /// it and caches the result both ways.
    @discardableResult
    func load(_ url: URL) async -> UIImage? {
        let key = stableKey(for: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let (task, isNew) = inFlightTaskOrRegister(forKey: key, url: url)
        let result = await task.value
        if isNew {
            clearInFlightTask(forKey: key)
        }
        return result
    }

    /// Returns the in-flight task for `key` if one's already running, otherwise creates,
    /// registers, and returns a new one — atomically, so two concurrent callers for the same
    /// key can't both decide to start their own fetch. Synchronous (unlike `load` itself) so
    /// the locking stays a plain, provably-safe critical section instead of straddling
    /// `async` suspension points.
    private func inFlightTaskOrRegister(forKey key: String, url: URL) -> (task: Task<UIImage?, Never>, isNew: Bool) {
        lock.withLock {
            if let existing = inFlightTasks[key] {
                return (existing, false)
            }
            let task = Task<UIImage?, Never> { [weak self] in
                await self?.fetch(url, key: key)
            }
            inFlightTasks[key] = task
            return (task, true)
        }
    }

    private func clearInFlightTask(forKey key: String) {
        lock.withLock { inFlightTasks[key] = nil }
    }

    private func fetch(_ url: URL, key: String) async -> UIImage? {
        if let onDisk = diskImage(forKey: key) {
            memory.setObject(onDisk, forKey: key as NSString)
            return onDisk
        }
        if let durable = durableImage(forKey: key) {
            memory.setObject(durable, forKey: key as NSString)
            return durable
        }
        guard let data = try? await URLSession.shared.data(from: url).0, let image = decodedImage(from: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        writeToDisk(data, forKey: key)
        return image
    }

    /// Starts downloading `url` in the background if it isn't already cached (or already in
    /// flight), without waiting for the result. Fire-and-forget.
    func prefetch(_ url: URL?) {
        guard let url else { return }
        Task { await load(url) }
    }

    /// Fetches `url`'s image if not already cached anywhere, and stores it durably under
    /// Application Support (survives `Caches/` eviction) in addition to the normal memory/
    /// Caches-disk tiers. For downloaded songs' artwork, so it's still available offline even
    /// under storage pressure. Returns whether the image ended up durably cached — already was,
    /// or was just fetched and stored — `false` only on a genuine failure (offline, deleted on
    /// server, ...).
    @discardableResult
    func precacheDurably(_ url: URL) async -> Bool {
        let key = stableKey(for: url)
        if let durableURL = durableURL(forKey: key), fileManager.fileExists(atPath: durableURL.path) {
            return true
        }
        if let cachesURL = diskURL(forKey: key), let data = try? Data(contentsOf: cachesURL) {
            writeDurably(data, forKey: key)
            if let image = decodedImage(from: data) { memory.setObject(image, forKey: key as NSString) }
            return true
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return false }
        writeToDisk(data, forKey: key)
        writeDurably(data, forKey: key)
        if let image = decodedImage(from: data) { memory.setObject(image, forKey: key as NSString) }
        return true
    }

    /// Drops every cached entry (memory and disk), e.g. when switching to a different server.
    func invalidateAll() {
        memory.removeAllObjects()
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func diskImage(forKey key: String) -> UIImage? {
        guard let fileURL = diskURL(forKey: key), let data = try? Data(contentsOf: fileURL) else { return nil }
        return decodedImage(from: data)
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

    private func durableImage(forKey key: String) -> UIImage? {
        guard let fileURL = durableURL(forKey: key), let data = try? Data(contentsOf: fileURL) else { return nil }
        return decodedImage(from: data)
    }

    private func writeDurably(_ data: Data, forKey key: String) {
        guard let fileURL = durableURL(forKey: key) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Fully decodes `data` into a plain device-RGB bitmap, off the main thread, right away —
    /// rather than handing back a `UIImage` that lazily decodes (via ImageIO's newer block-based
    /// decoder) whenever UIKit/SwiftUI first draws it. That lazy path has a real, filed Apple bug
    /// (rdar://143602439, logged as "kCGImageBlockFormatBGRx8 is called for 24-bpp (8-bpc)
    /// image") that can hang the *main* thread mid-decode for certain JPEGs — which read as a
    /// random app freeze, since it only fires whenever some particular image happens to first
    /// scroll/switch into view. Forcing the real decode here, on a background task, means the
    /// image handed to SwiftUI is already a plain bitmap with nothing left to lazily (and
    /// buggily) decode on the main thread.
    private func decodedImage(from data: Data) -> UIImage? {
        guard let source = UIImage(data: data), let cgImage = source.cgImage else { return nil }
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
        ) else { return source }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else { return source }
        return UIImage(cgImage: normalized, scale: source.scale, orientation: .up)
    }
}

/// A drop-in replacement for `AsyncImage(url:content:placeholder:)` that checks `ImageCache`
/// first — synchronously, at init — so a cache hit renders on the very first frame instead of
/// flashing the placeholder while a redundant fetch happens.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    /// Fires whenever a `UIImage` is obtained for `url` (a cache hit or a fresh load) — lets a
    /// caller that needs the raw bitmap itself (e.g. to sample its average color) get it directly,
    /// instead of re-deriving one from the wrapped `Image` via `ImageRenderer`, which would mean
    /// redundantly re-rendering an image that's already been decoded.
    private let onLoad: ((UIImage) -> Void)?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    /// The url `uiImage` was actually loaded for, so a changed `url` on an otherwise-identical
    /// view (e.g. the mini player swapping tracks) is recognized as needing a reload — `@State`
    /// survives across re-inits of this struct, so checking `uiImage == nil` alone would leave
    /// the previous track's artwork on screen forever once one image had loaded.
    @State private var loadedURL: URL?

    init(
        url: URL?,
        onLoad: ((UIImage) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.onLoad = onLoad
        self.content = content
        self.placeholder = placeholder
        let cached = url.flatMap(ImageCache.shared.image(for:))
        _uiImage = State(initialValue: cached)
        _loadedURL = State(initialValue: cached != nil ? url : nil)
        if let cached { onLoad?(cached) }
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
        guard loadedURL != url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            uiImage = cached
            loadedURL = url
            onLoad?(cached)
            return
        }
        guard let image = await ImageCache.shared.load(url) else { return }
        await MainActor.run {
            if self.url == url {
                uiImage = image
                loadedURL = url
                onLoad?(image)
            }
        }
    }
}
