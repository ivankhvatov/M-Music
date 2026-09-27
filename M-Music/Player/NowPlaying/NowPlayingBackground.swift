import SwiftUI

/// The mini player's pill-shaped material backing that morphs into the full-screen colorful
/// backdrop as the player expands, corner radius and all.
struct NowPlayingBackground: View {
    let colors: [Color]
    let expanded: Bool
    /// Drives just the glass-vs-colorful fill crossfade below — kept separate from `expanded`
    /// (which alone drives the shape: frame height and corner radius, further down) so that
    /// during a collapse the fill can keep showing the colorful/expanded look, in lockstep with
    /// `ExpandableNowPlaying`'s own content, for most of the shrink and only swap to real Liquid
    /// Glass right at the end. `expanded` itself must still start the shape shrinking immediately.
    let showsExpandedContent: Bool
    let isFullExpanded: Bool
    /// 1 for full color, 0 for grayscale — animated down to 0 by `ExpandableNowPlaying` right as a
    /// collapse commits, faster than the shape/material morph itself, so the colorful gradient
    /// visibly desaturates to gray *before* it cross-fades into the Liquid Glass pill rather than
    /// cutting from full color straight to glass.
    var saturation: CGFloat = 1

    var body: some View {
        ZStack {
            // Real Liquid Glass (not an approximation) so the collapsed pill is pixel-identical
            // to the system-rendered `.tabViewBottomAccessory` sitting underneath it — that's
            // what lets `ExpandableNowPlaying` hide this overlay with a plain cut instead of a
            // cross-fade and still read as a seamless morph.
            //
            // `.animation(nil, value: showsExpandedContent)` on both layers below: without it,
            // this crossfade would pick up whatever `withAnimation` is ambient at the time (the
            // same one driving the pill's frame/corner-radius morph) and stretch itself across
            // that full duration — reading as the content "materializing" over the shape, rather
            // than the shape alone morphing. Cutting it makes the glass-to-colorful swap instant
            // while the surrounding shape keeps animating normally.
            Color.clear
                // `.clear` (not `.regular`) — the real `.tabViewBottomAccessory` reads as more
                // transparent than `.regular` glass; `.clear` is the variant that lets more of
                // what's behind it show through, matching that look instead of a more opaque
                // frosted-glass appearance.
                .glassEffect(.regular, in: .rect(cornerRadius: playerCornerRadius))
                .opacity(showsExpandedContent ? 0 : 1)
                .animation(nil, value: showsExpandedContent)
            ColorfulBackground(colors: colors, isActive: showsExpandedContent)
                // Blending toward black (rather than the mid-gray this used to use) darkens the
                // gradient while leaving its hue and saturation alone — a gray wash pulls every
                // color toward gray, which is what was flattening/desaturating this background.
                .overlay(Color.gray.darkened(by: 0.15).opacity(0.3))
                .saturation(saturation)
                // Darkens in lockstep with the desaturation above — both are driven by the same
                // `saturation` value, so by the time the gradient has gone fully gray it has also
                // dimmed down toward the Liquid Glass pill's own dark tone. Without this, a
                // desaturated-but-still-bright gray would cross-fade into the pill as a visible
                // lightening instead of reading as a continuation of the same surface.
                .overlay(Color.gray.darkened(by: Const.collapseDarkenOpacity).opacity(1.0 - saturation))
                .opacity(showsExpandedContent ? 1 : 0)
                .animation(nil, value: showsExpandedContent)
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

    enum Const {
        /// How far the gradient darkens toward black by the time `saturation` reaches 0 — see the
        /// darkening `.overlay` above.
        static let collapseDarkenOpacity: CGFloat = 0.4
    }
}
