import Combine
import SwiftUI

@Observable
final class ColorfulBackgroundModel {
    static let animationDuration: Double = 40
    var points: ColorPoints = .zero.shuffled

    private var colors: [Color] = []
    private var shown = false
    private var animatedData: ColorPoints = .zero
    private var animationTimerCancellable: AnyCancellable?

    func onAppear() {
        shown = true
        animate()
        animatedData = points

        animationTimerCancellable = Timer
            .publish(every: Self.animationDuration * 0.9, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.animate()
            }
    }

    func onUpdate(animatedData: ColorPoints) {
        self.animatedData = animatedData
    }

    func set(_ colors: [Color]) {
        guard colors != self.colors else { return }
        self.colors = colors
        if shown {
            withAnimation {
                points = animatedData.colored(colors: colors)
            }
        } else {
            // Before the first `animate()` runs, `animatedData` is still its placeholder `.zero`
            // — every position (0, 0) — so colored(colors:) would put all 3 real colors on top
            // of each other in the corner, and the very first `animate()` call would then spend
            // its whole 20s linear animation slowly separating them, reading as a near-solid
            // color for a good stretch of the opening. `points` already holds real, spread-out
            // positions from `.zero.shuffled` at init, so color those instead.
            points = points.colored(colors: colors)
        }
    }

    func animate() {
        withAnimation(.linear(duration: Self.animationDuration)) {
            points = points.shuffled
        }
    }
}
