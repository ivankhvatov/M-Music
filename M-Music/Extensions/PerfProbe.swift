#if DEBUG
import Darwin
import Foundation
import os

/// Logs where the app's CPU goes, once a second: the total, the main thread's share and the busiest
/// threads by name. For finding out *what* is busy during a scroll before guessing at fixes — start
/// it by launching with `-PerfProbe` (Xcode scheme → Arguments Passed On Launch) and read the
/// console, or call `PerfProbe.start()` from anywhere.
enum PerfProbe {
    private static let logger = Logger(subsystem: "M-Music", category: "PerfProbe")
    private static let state = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    static func startIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("-PerfProbe") { start() }
    }

    static func start() {
        state.withLock { task in
            guard task == nil else { return }
            task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    log(sample())
                }
            }
        }
    }

    static func stop() {
        state.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    struct ThreadLoad {
        let name: String
        let percent: Double
        let isMain: Bool
    }

    /// The CPU use of every thread of the process right now (since the previous sample, as the
    /// kernel reports it), busiest first.
    static func sample() -> [ThreadLoad] {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var loads: [ThreadLoad] = []
        for index in 0..<Int(count) {
            let thread = threads[index]
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            var name = [CChar](repeating: 0, count: 64)
            if let pthread = pthread_from_mach_thread_np(thread) {
                pthread_getname_np(pthread, &name, name.count)
            }
            let label = String(cString: name)
            loads.append(ThreadLoad(
                name: label.isEmpty ? "thread-\(index)" : label,
                percent: Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100,
                isMain: index == 0
            ))
        }
        return loads.sorted { $0.percent > $1.percent }
    }

    private static func log(_ loads: [ThreadLoad]) {
        let total = loads.reduce(0) { $0 + $1.percent }
        let main = loads.first(where: \.isMain)?.percent ?? 0
        let top = loads.prefix(5).map { "\($0.isMain ? "main" : $0.name)=\(Int($0.percent))%" }.joined(separator: " ")
        logger.notice("CPU total=\(Int(total))% main=\(Int(main))% top: \(top, privacy: .public)")
    }
}
#endif
