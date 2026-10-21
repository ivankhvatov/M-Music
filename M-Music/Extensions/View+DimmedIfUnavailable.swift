import SwiftUI

extension View {
    /// The app-wide "not available" look — `isAvailable` should already fold in
    /// `NetworkMonitor.shared.isOnline` (nothing is ever unavailable while online, since
    /// everything can still stream), so this only ever visibly kicks in while offline. Dimming
    /// alone doesn't stop taps from reaching a `Button`/`NavigationLink` this is nested inside of
    /// as its label — callers also need `.disabled(!isAvailable)` on that control itself, using
    /// the same `isAvailable` value, wherever this is used on a tappable row/card.
    ///
    /// An available view is returned untouched: `.saturation(1)` isn't free — it adds a
    /// colour-matrix effect to every card and row in a scrolling list even though it changes
    /// nothing, which is exactly the common (online) case.
    @ViewBuilder
    func dimmedIfUnavailable(_ isAvailable: Bool) -> some View {
        if isAvailable {
            self
        } else {
            opacity(0.4)
                .saturation(0.3)
        }
    }
}
