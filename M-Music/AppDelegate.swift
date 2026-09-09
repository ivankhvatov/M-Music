import UIKit

/// Downloads run on a background `URLSession` (see `DownloadService`) so they keep going if the
/// app is backgrounded or suspended mid-download. iOS wakes the app and calls this method to
/// relaunch that session and replay its events; the completion handler it hands us must be called
/// once `DownloadService` has finished processing them, or the system assumes the app hung.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { await DownloadService.shared.setBackgroundCompletionHandler(completionHandler, forSession: identifier) }
    }
}
