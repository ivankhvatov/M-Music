import UIKit

/// Downloads run on a background `URLSession` (see `DownloadService`) so they keep going if the
/// app is backgrounded or suspended mid-download. iOS wakes the app and calls this method to
/// relaunch that session and replay its events; the completion handler it hands us must be called
/// once `DownloadService` has finished processing them, or the system assumes the app hung.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Runs before any view is built, so before anything asks for an image.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Some decode tiers are as big as this screen needs. Read here and not in the `App`'s
        // initializer: UIKit isn't set up there yet, and touching the screen that early lost the
        // asset catalog's accent color — everything tinted came out blue.
        ImageCache.setScreenSize(width: UIScreen.main.bounds.width, scale: UIScreen.main.scale)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { await DownloadService.shared.setBackgroundCompletionHandler(completionHandler, forSession: identifier) }
    }
}
