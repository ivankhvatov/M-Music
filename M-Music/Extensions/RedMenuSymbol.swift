import SwiftUI

/// A menu item's symbol in red whatever the screen's tint is. A destructive menu item is red, but
/// the album and playlist screens set `.tint(.primary)`, which turns its symbol white; an image
/// with a fixed color (`.alwaysOriginal`) isn't tinted.
func redMenuSymbol(_ systemName: String) -> Image {
    guard let symbol = UIImage(systemName: systemName)?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) else {
        return Image(systemName: systemName)
    }
    return Image(uiImage: symbol)
}
