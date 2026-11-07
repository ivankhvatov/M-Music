import Combine
import SwiftUI

@Observable
final class ColorfulBackgroundModel {
    static let animationDuration: Double = 40
    /// How long after the player starts expanding the drift begins: the morph's own duration, so
    /// the gradient holds still while the pill grows — it moves so slowly that nothing shows — and
    /// the morph has that much less to do.
    static let startDelay: Double = Animation.playerExpandAnimationDuration + 0.05

    var points: ColorPoints = .zero.shuffled
    /// Identifies the gradient view in `ColorfulBackground`; bumped by `stop()`, since replacing
    /// the view is what actually ends its animation (see there).
    private(set) var generation = 0

    private var colors: [Color] = []
    /// Whether the drift is running — from `start()` until `stop()`.
    private var isActive = false
    /// The wait between `setActive(true)` and `start()`.
    private var startTask: Task<Void, Never>?
    private var animatedData: ColorPoints = .zero
    private var animationTimerCancellable: AnyCancellable?

    /// Runs the background animation only while it's actually visible. This used to start at
    /// launch and never stop — a 40s linear animation restarted by a repeating timer, driving an
    /// `Animatable` view (rebuilding 8 color points and a Metal-shader uniforms blob every frame)
    /// for the whole life of the process, even while the player was collapsed and this whole
    /// layer sat at opacity 0. `NowPlayingBackground` mounts this permanently (so there's no
    /// first-show hitch), so the animation itself is what has to be switched off.
    ///
    /// Switching on waits `startDelay` (the morph into the expanded player), switching off is
    /// at once.
    func setActive(_ active: Bool) {
        if active {
            guard !isActive, startTask == nil else { return }
            startTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.startDelay))
                guard !Task.isCancelled, let self else { return }
                self.startTask = nil
                self.start()
            }
        } else {
            startTask?.cancel()
            startTask = nil
            guard isActive else { return }
            stop()
        }
    }

    private func start() {
        isActive = true
        animate()
        animatedData = points

        animationTimerCancellable = Timer
            .publish(every: Self.animationDuration * 0.9, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.animate()
            }
    }

    /// Freezes the gradient where it currently is. Assigning the last animated position back
    /// without an animation is not enough to end the in-flight one: the view's animation went on
    /// ticking, hidden, for a good while, and was still running when the next expand started a new
    /// one over it — a ~100 ms frame, every time after the first. So the gradient view is also
    /// replaced (`generation`), which takes the animation with it. (Only safe while the gradient
    /// is out of sight: the new view draws nothing for a moment, so stopping it while it's shown —
    /// at the start of a collapse — made it vanish from the shrinking pill.)
    private func stop() {
        isActive = false
        animationTimerCancellable?.cancel()
        animationTimerCancellable = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            points = animatedData
            generation &+= 1
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
