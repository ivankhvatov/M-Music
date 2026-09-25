import Combine
import SwiftUI

@Observable
final class ColorfulBackgroundModel {
    static let animationDuration: Double = 40
    var points: ColorPoints = .zero.shuffled

    private var colors: [Color] = []
    private var isActive = false
    private var animatedData: ColorPoints = .zero
    private var animationTimerCancellable: AnyCancellable?

    /// Runs the background animation only while it's actually visible. This used to start at
    /// launch and never stop — a 40s linear animation restarted by a repeating timer, driving an
    /// `Animatable` view (rebuilding 8 color points and a Metal-shader uniforms blob every frame)
    /// for the whole life of the process, even while the player was collapsed and this whole
    /// layer sat at opacity 0. `NowPlayingBackground` mounts this permanently (so there's no
    /// first-show hitch), so the animation itself is what has to be switched off.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        animate()
        animatedData = points

        animationTimerCancellable = Timer
            .publish(every: Self.animationDuration * 0.9, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.animate()
            }
    }

    /// Freezes the gradient where it currently is: assigning the last animated position back
    /// without an animation replaces the in-flight one, so nothing keeps ticking.
    private func stop() {
        animationTimerCancellable?.cancel()
        animationTimerCancellable = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            points = animatedData
        }
    }

    func onUpdate(animatedData: ColorPoints) {
        self.animatedData = animatedData
    }

    func set(_ colors: [Color]) {
        guard colors != self.colors else { return }
        self.colors = colors
        if isActive {
            withAnimation {
                points = animatedData.colored(colors: colors)
            }
        } else {
            // While inactive (before the first `animate()` has ever run, or frozen after
            // `stop()`), recolor the positions `points` already holds, without animating: before
            // the first `animate()`, `animatedData` is still its placeholder `.zero` — every
            // position (0, 0) — so colored(colors:) on *that* would put all 3 real colors on top
            // of each other in the corner, and the first `animate()` would then spend its whole
            // linear animation slowly separating them, reading as a near-solid color for a good
            // stretch of the opening. `points` always holds real, spread-out positions.
            points = points.colored(colors: colors)
        }
    }

    func animate() {
        withAnimation(.linear(duration: Self.animationDuration)) {
            points = points.shuffled
        }
    }
}
