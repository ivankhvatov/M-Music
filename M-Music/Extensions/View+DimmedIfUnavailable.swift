import SwiftUI

extension View {
    /// The app-wide "not available" look — `isAvailable` should already fold in
    /// `NetworkMonitor.shared.isOnline` (nothing is ever unavailable while online, since
    /// everything can still stream), so this only ever visibly kicks in while offline. Dimming
    /// alone doesn't stop taps from reaching a `Button`/`NavigationLink` this is nested inside of
    /// as its label — callers also need `.disabled(!isAvailable)` on that control itself, using
    /// the same `isAvailable` value, wherever this is used on a tappable row/card.
    @ViewBuilder
    func dimmedIfUnavailable(_ isAvailable: Bool) -> some View {
        opacity(isAvailable ? 1 : 0.4)
            .saturation(isAvailable ? 1 : 0.3)
    }
}
