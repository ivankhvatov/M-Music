import SwiftUI

/// Defers building a `NavigationLink`'s destination until it is actually shown.
///
/// Every `NavigationLink` initializer evaluates its destination when the link itself is built —
/// the `destination:` autoclosure and the `{ }` builder form alike — so `NavigationLink(destination:
/// AlbumView(...))` constructs a full `AlbumView` (a signed cover URL, a handful of `@State`s and
/// `@AppStorage`s) for every visible card, on every re-render of the parent screen. Wrapping the
/// destination here means only this small struct, holding the closure, is built per link; the real
/// view is created when the push happens.
struct LazyDestination<Content: View>: View {
    let build: () -> Content

    var body: some View {
        build()
    }
}
