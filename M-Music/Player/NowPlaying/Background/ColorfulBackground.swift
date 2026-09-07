import SwiftUI

/// An animated, softly-blurred multicolor gradient built from a track's dominant artwork colors —
/// the blob-of-color backdrop behind Apple Music's full-screen Now Playing view.
struct ColorfulBackground: View {
    @State var model = ColorfulBackgroundModel()
    let colors: [Color]

    var body: some View {
        MulticolorGradient(
            points: model.points,
            animationUpdateHandler: model.onUpdate(animatedData:)
        )
        .onAppear {
            model.set(colors)
            model.onAppear()
        }
        .onChange(of: colors) {
            model.set(colors)
        }
    }
}
