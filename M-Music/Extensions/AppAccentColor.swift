import SwiftUI

extension Color {
    /// The app's accent color from the asset catalog, fixed: unlike `Color.accentColor`, it
    /// doesn't follow the environment's tint, which the album and playlist screens set to
    /// `.primary` and their sheets inherit.
    static let appAccent = Color("AccentColor")
}
