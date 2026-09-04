import SwiftUI

/// A brief circle that bursts outward and fades on tap — the same kind of feedback Apple Music
/// gives its play/pause button. `trigger` increments on every tap; each new value restarts the
/// animation from scratch (a plain `withAnimation` on a boolean would just interpolate from
/// wherever the previous burst left off instead of starting over).
struct PlayPauseBurst: View {
    let trigger: Int
    var color: Color = .white
    let endScale: CGFloat

    // Both the untapped resting state and the settled-after-burst state need to be invisible —
    // unlike a single `expanded` toggle, these two independent values let opacity start and end
    // at 0 while still animating up to 0.55 and back down as the circle expands in between.
    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(scale)
            .opacity(opacity)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                scale = 0.6
                opacity = 0.55
                try? await Task.sleep(for: .seconds(0.01))
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = endScale
                    opacity = 0
                }
            }
    }
}
