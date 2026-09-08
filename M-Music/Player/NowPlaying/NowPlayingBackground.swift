import SwiftUI

/// The mini player's pill-shaped material backing that morphs into the full-screen colorful
/// backdrop as the player expands, corner radius and all.
struct NowPlayingBackground: View {
    let colors: [Color]
    let expanded: Bool
    let isFullExpanded: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thickMaterial)
            ColorfulBackground(colors: colors)
                // Blending toward black (rather than the mid-gray this used to use) darkens the
                // gradient while leaving its hue and saturation alone — a gray wash pulls every
                // color toward gray, which is what was flattening/desaturating this background.
                .overlay(Color.black.opacity(0.4))
                .opacity(expanded ? 1 : 0)
        }
        .clipShape(.rect(cornerRadius: playerCornerRadius))
        .frame(height: expanded ? nil : NowPlayingLayout.compactHeight)
    }
}

extension NowPlayingBackground {
    /// Shared with `ExpandableNowPlaying`, which clips its whole stack (background *and*
    /// content) to this same shape — the two must always agree, or the content's clip would
    /// visibly disagree with the background's own rounded corners as they animate together.
    static func cornerRadius(expanded: Bool, isFullExpanded: Bool) -> CGFloat {
        expanded
            ? (isFullExpanded ? 0 : UIScreen.deviceCornerRadius)
            : NowPlayingLayout.compactHeight / 2
    }
}

private extension NowPlayingBackground {
    var playerCornerRadius: CGFloat {
        Self.cornerRadius(expanded: expanded, isFullExpanded: isFullExpanded)
    }
}
