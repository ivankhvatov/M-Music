import SwiftUI

@main
struct M_MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    public var mainView = MainView()

    init() {
        PerfLog.appLaunched()
    }

    var body: some Scene {
        WindowGroup {
            mainView
        }
    }
}
