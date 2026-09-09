import Foundation
import Network

/// Tracks the device's current connection type so transcoding decisions (`TranscodingSettings`)
/// can be made against Wi-Fi vs. cellular without each call site standing up its own
/// `NWPathMonitor`.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.path = path }
        }
        monitor.start(queue: queue)
    }

    var isOnWiFi: Bool {
        lock.withLock { path?.usesInterfaceType(.wifi) ?? false }
    }

    var isOnCellular: Bool {
        lock.withLock { path?.usesInterfaceType(.cellular) ?? false }
    }

    /// Whether the device currently has any usable network path at all — used to skip
    /// prefetching/downloading rather than let it fail immediately.
    var hasNetwork: Bool {
        lock.withLock { path?.status == .satisfied }
    }
}
