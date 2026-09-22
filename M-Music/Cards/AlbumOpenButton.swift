import SwiftUI

/// Wraps an album card/row so tapping it first makes sure the album's full-size artwork (the
/// same one `AlbumView`'s header requests) is already loaded, and only opens `AlbumView`
/// afterward — instead of pushing immediately and letting the artwork visibly pop in a moment
/// later once `AlbumView`'s own `CachedAsyncImage` finishes loading it. Capped at `maxWait` so a
/// slow or offline fetch can't leave a tap feeling unresponsive; past that, it opens anyway and
/// falls back to today's placeholder-then-pop-in behavior.
struct AlbumOpenButton<Label: View>: View {
    let album: AlbumID3
    let onOpen: (AlbumID3) -> Void
    @ViewBuilder let label: () -> Label

    private static var maxWait: TimeInterval { 2.5 }

    @State private var isOpening = false

    var body: some View {
        Button(action: open) { label() }
            .buttonStyle(.plain)
            .disabled(isOpening)
    }

    private func open() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            if let url = try? SubsonicClient.shared.coverArtURL(forId: album.coverArt ?? album.id.raw) {
                await ImageCache.shared.load(url, timeout: Self.maxWait)
            }
            isOpening = false
            onOpen(album)
        }
    }
}
