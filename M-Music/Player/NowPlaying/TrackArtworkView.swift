import SwiftUI

/// Cover artwork with a subtle border, used by both the compact mini player and the expanded Now
/// Playing screen. Square unless the actual image isn't — in which case it's fit (not cropped)
/// within the square tile, and the rounded corners and border apply to the image's own bounds
/// rather than to a square background behind it, so there's no visible letterboxing.
struct TrackArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        // Full-resolution bitmap (not the standard capped one) — the expanded Now Playing artwork
        // is the one place a cover is shown large enough (~1050px at 3x) for the cap to be visible.
        // Only ever one of these decoded at a time (the current track's), so the cost that cap
        // exists to avoid on list screens doesn't apply here.
        CachedAsyncImage(url: url, maxPixelSize: nil) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .roundedArtworkBorder(cornerRadius: cornerRadius)
        } placeholder: {
            ZStack {
                Color(.systemGray5)
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            .roundedArtworkBorder(cornerRadius: cornerRadius)
        }
    }
}

private extension View {
    /// The rounded corners + subtle hairline border shared by every artwork tile — applied to
    /// each case's own actual bounds (the fit-sized image, or the square placeholder) rather than
    /// to a common square wrapper, so a non-square image's rounding follows its own edges instead
    /// of the outer square it's letterboxed within.
    func roundedArtworkBorder(cornerRadius: CGFloat) -> some View {
        let border = UIScreen.hairlineWidth
        return clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: border / 2)
                    .stroke(Color.black.opacity(0.15), lineWidth: border)
            )
    }
}
