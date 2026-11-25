import SwiftUI

extension EnvironmentValues {
    /// Set under the Search tab when its search field is the system's (the tab has the search role):
    /// a screen there can't change the window's colour scheme as it's pushed without losing its push
    /// animation — see `View.darkAppearance()`.
    @Entry var keepsSystemColorScheme = false
}

extension View {
    /// The dark look of the album and playlist screens. Normally the whole screen, bars included,
    /// is switched to dark with `preferredColorScheme`. Under the system search tab that switch
    /// makes the push open without any animation, so there only the content and the navigation bar
    /// are made dark and the window's own scheme is left alone.
    func darkAppearance() -> some View {
        modifier(DarkAppearance())
    }
}

private struct DarkAppearance: ViewModifier {
    @Environment(\.keepsSystemColorScheme) private var keepsSystemColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if keepsSystemColorScheme {
            content
                .environment(\.colorScheme, .dark)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            content.preferredColorScheme(.dark)
        }
    }
}
