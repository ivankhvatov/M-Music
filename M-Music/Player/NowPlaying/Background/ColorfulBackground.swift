import SwiftUI

/// An animated, softly-blurred multicolor gradient built from a track's dominant artwork colors —
/// the blob-of-color backdrop behind Apple Music's full-screen Now Playing view.
struct ColorfulBackground: View {
    @State var model = ColorfulBackgroundModel()
    let colors: [Color]
    /// Whether the background is actually on screen (see `ColorfulBackgroundModel.setActive`) —
    /// it stays mounted while hidden, but must not animate.
    let isActive: Bool

    var body: some View {
        MulticolorGradient(
            points: model.points,
            animationUpdateHandler: model.onUpdate(animatedData:)
        )
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
