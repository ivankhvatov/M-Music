import SwiftUI
import UIKit

/// Whether the app is in the foreground, and how many times it has come back to it.
///
/// Read through `Observation`, so a view that reads either value in its body is updated when it
/// changes. It is fed by the application's notifications rather than `scenePhase`: that isn't
/// reliably delivered inside every hosting hierarchy (the tab bar's bottom accessory, notably), and
/// the player's buttons live in several.
///
/// The player's buttons use it to start over each time the app returns: an animation that was in
/// flight when the app left the screen isn't always finished, or replayed, on the way back, and the
/// view is then left standing in the middle of it — see `PlayerButton`.
@MainActor
@Observable
final class AppActivity {
    static let shared = AppActivity()

    /// False from the moment the app is about to resign (a lock, Home, a call, Control Center) until
    /// it's active again.
    private(set) var isActive: Bool
    /// Bumped each time the app becomes active again. Used as a view identity, so what hangs on it
    /// is built afresh on every return.
    private(set) var resumeCount = 0

    private init() {
        isActive = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isActive = true
                self?.resumeCount &+= 1
            }
        }
    }
}
