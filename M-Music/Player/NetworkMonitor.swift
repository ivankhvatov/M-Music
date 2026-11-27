import Foundation
import Network

/// Tracks the device's current connection type so transcoding decisions (`TranscodingSettings`)
/// can be made against Wi-Fi vs. cellular without each call site standing up its own
/// `NWPathMonitor`.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    /// Posted on the main queue when the network path changes.
    static let pathDidChange = Notification.Name("NetworkMonitor.pathDidChange")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let lock = NSLock()
    private var path: NWPath?

    /// A SwiftUI-observable mirror of `hasNetwork`, for views that gray out/disable content while
    /// offline (`dimmedIfUnavailable`) — `hasNetwork` itself stays a plain lock-protected property
    /// since it's also read from `StreamCacheService`, a background actor that can't safely
    /// observe `@Published` the way a view can. Defaults to `true` so a normal, online launch
    /// doesn't flash everything as unavailable before `NWPathMonitor`'s first callback arrives.
    @Published private(set) var isOnline: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.path = path }
            let isOnline = path.status == .satisfied
            // `@Published` announces every assignment even when the value is the same, and every
            // list row observes this — so an unchanged path update (which the system sends on
            // things like returning to the foreground) would re-render every row for nothing.
            DispatchQueue.main.async {
                if self.isOnline != isOnline { self.isOnline = isOnline }
                NotificationCenter.default.post(name: Self.pathDidChange, object: self)
            }
        }
        monitor.start(queue: queue)
    }

    var isOnWiFi: Bool {
        lock.withLock { path?.usesInterfaceType(.wifi) ?? false }
    }

    var isOnCellular: Bool {
        lock.withLock { path?.usesInterfaceType(.cellular) ?? false }
    }

    /// Whether downloads nobody asked for may run: on Wi-Fi or a cable, but not a metered one
    /// (a phone's hotspot is) and not in Low Data Mode.
    var allowsBackgroundDownloads: Bool {
        lock.withLock {
            guard let path, path.status == .satisfied, !path.isExpensive, !path.isConstrained else { return false }
            return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        }
    }

    /// Whether the device currently has any usable network path at all — used to skip
    /// prefetching/downloading rather than let it fail immediately.
    var hasNetwork: Bool {
        lock.withLock { path?.status == .satisfied }
    }
}
