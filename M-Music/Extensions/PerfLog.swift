import Darwin
import Foundation
import os

/// The timing logs performance changes are measured with: `PERF …` lines in Xcode's console, and
/// events and intervals in Instruments' Points of Interest track. In Release builds too, which is
/// what's worth measuring on a device — filter the console by "PERF". Only counts, sizes and times
/// are logged, nothing that names anything in the library.
///
/// - launch → Home's content on screen
/// - how long a screen waited for its covers (see `ImageWarmer.prepare`)
/// - a track's load → audio playing
/// - what artwork has cost since launch (downloads and decodes), with the app's memory use
enum PerfLog {
    private static let logger = Logger(subsystem: "M-Music", category: "Perf")
    private static let signposter = OSSignposter(subsystem: "M-Music", category: .pointsOfInterest)
    /// How long after artwork activity starts the running totals are logged, so a screenful of
    /// covers makes one line and not dozens.
    private static let summaryDelay: Duration = .seconds(3)

    private struct State: Sendable {
        var appStart: ContinuousClock.Instant?
        var homeShown = false
        var trackLoadStart: ContinuousClock.Instant?
        var downloads = 0
        var downloadedBytes = 0
        var decodes = 0
        var decodeTime: Duration = .zero
        var bitmapBytes = 0
        var summaryScheduled = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Launch

    /// Called from the app's initializer.
    static func appLaunched() {
        state.withLock { $0.appStart = ContinuousClock.now }
        signposter.emitEvent("App init")
    }

    /// Home's carousels came on screen. Only the first time after a launch counts.
    static func homeContentShown() {
        let appStart = state.withLock { state -> ContinuousClock.Instant? in
            guard !state.homeShown else { return nil }
            state.homeShown = true
            return state.appStart
        }
        guard let appStart else { return }
        signposter.emitEvent("Home content")
        var message = "launch → Home content: \(milliseconds(ContinuousClock.now - appStart)) ms from app init"
        // The system may have started a "prewarmed" process long before the launch was asked for.
        if ProcessInfo.processInfo.environment["ActivePrewarm"] != "1", let total = millisecondsSinceProcessStart() {
            message += ", \(total) ms from process start"
        }
        log(message)
    }

    // MARK: - Covers

    /// A screen's covers were all in memory already, so it didn't wait.
    static func coversReady(screen fileID: String, count: Int) {
        log("covers \(screenName(fileID)): \(count) wanted, all in memory")
    }

    /// A screen starts waiting for covers. Call what's returned once it stops.
    static func beginCoversWait(screen fileID: String, count: Int, missing: Int, limit: Duration) -> () -> Void {
        let start = ContinuousClock.now
        let interval = signposter.beginInterval("Covers wait", id: signposter.makeSignpostID())
        return {
            signposter.endInterval("Covers wait", interval)
            let waited = milliseconds(ContinuousClock.now - start)
            log("covers \(screenName(fileID)): \(count) wanted, \(missing) not in memory, waited \(waited) ms (limit \(milliseconds(limit)) ms)")
        }
    }

    // MARK: - Playback

    static func trackLoadStarted() {
        state.withLock { $0.trackLoadStart = ContinuousClock.now }
    }

    /// The load in progress won't end in audio (paused, or loaded without playing).
    static func trackLoadCancelled() {
        state.withLock { $0.trackLoadStart = nil }
    }

    /// Sound is coming out. Logs only if a track load is being timed.
    static func audioStarted(source: String) {
        let start = state.withLock { state -> ContinuousClock.Instant? in
            defer { state.trackLoadStart = nil }
            return state.trackLoadStart
        }
        guard let start else { return }
        signposter.emitEvent("Audio playing")
        log("track load → audio (\(source)): \(milliseconds(ContinuousClock.now - start)) ms")
    }

    // MARK: - Artwork

    static func artworkDownloaded(bytes: Int) {
        recordArtwork {
            $0.downloads += 1
            $0.downloadedBytes += bytes
        }
    }

    static func artworkDecoded(took duration: Duration, bitmapBytes: Int) {
        recordArtwork {
            $0.decodes += 1
            $0.decodeTime += duration
            $0.bitmapBytes += bitmapBytes
        }
    }

    private static func recordArtwork(_ change: @Sendable (inout State) -> Void) {
        let schedulesSummary = state.withLock { state -> Bool in
            change(&state)
            guard !state.summaryScheduled else { return false }
            state.summaryScheduled = true
            return true
        }
        guard schedulesSummary else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: summaryDelay)
            let totals = state.withLock { state -> State in
                state.summaryScheduled = false
                return state
            }
            let memory = memoryFootprint().map { ", app memory \(megabytes($0))" } ?? ""
            log("artwork since launch: \(totals.downloads) downloads (\(megabytes(totals.downloadedBytes))), "
                + "\(totals.decodes) decodes (\(milliseconds(totals.decodeTime)) ms, "
                + "\(megabytes(totals.bitmapBytes)) of bitmaps)\(memory)")
        }
    }

    // MARK: - Helpers

    private static func log(_ message: String) {
        logger.notice("PERF \(message, privacy: .public)")
    }

    /// "M_Music/AlbumsListView.swift" → "AlbumsListView".
    private static func screenName(_ fileID: String) -> String {
        let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
        return file.replacingOccurrences(of: ".swift", with: "")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// From when the kernel started the process, which counts the loading that precedes the app's
    /// own first line of code.
    private static func millisecondsSinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let seconds = Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return Int(seconds * 1000)
    }

    /// The memory the system charges the app for — what Xcode's memory gauge shows.
    private static func memoryFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }
}
