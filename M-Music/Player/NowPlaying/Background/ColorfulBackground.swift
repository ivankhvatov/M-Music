import SwiftUI

/// An animated, softly-blurred multicolor gradient built from a track's dominant artwork colors —
/// the blob-of-color backdrop behind Apple Music's full-screen Now Playing view.
struct ColorfulBackground: View {
    @State var model = ColorfulBackgroundModel()
    let colors: [Color]
    /// Whether the gradient should drift (see `ColorfulBackgroundModel.setActive`) — while the
    /// expanded look is showing; it stays mounted while collapsed, but must not animate.
    let isActive: Bool

    var body: some View {
        MulticolorGradient(
            points: model.points,
            animationUpdateHandler: model.onUpdate(animatedData:)
        )
        // A new identity after every stop: that, not assigning the position back, is what ends
        // the old view's animation — see `ColorfulBackgroundModel.stop()`.
        .id(model.generation)
        .onAppear {
            model.set(colors)
            model.setActive(isActive)
        }
        .onDisappear {
            model.setActive(false)
        }
        .onChange(of: isActive) {
            model.setActive(isActive)
        }
        .onChange(of: colors) {
            model.set(colors)
        }
    }
}
