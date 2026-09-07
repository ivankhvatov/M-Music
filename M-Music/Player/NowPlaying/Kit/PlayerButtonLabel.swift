import SwiftUI

enum PlayerButtonType {
    case play
    case pause
    case backward
    case forward
}

/// Restarts an `AnimatedForwardLabel`'s morph animation. Alternates between two cases (rather
/// than a single toggled bool) so a rapid double-tap always triggers a fresh `onChange`, even if
/// it would otherwise land back on the same value.
enum PlayerButtonTrigger: Equatable {
    case one(bouncing: Bool)
    case another(bouncing: Bool)

    mutating func toggle(bouncing: Bool) {
        switch self {
        case .one: self = .another(bouncing: bouncing)
        case .another: self = .one(bouncing: bouncing)
        }
    }
}

struct PlayerButtonLabel: View {
    let type: PlayerButtonType
    let size: CGFloat
    var animationTrigger: PlayerButtonTrigger

    init(type: PlayerButtonType, size: CGFloat, animationTrigger: PlayerButtonTrigger? = nil) {
        self.type = type
        self.size = size
        self.animationTrigger = animationTrigger ?? .one(bouncing: false)
    }

    var body: some View {
        switch type {
        case .forward:
            AnimatedForwardLabel(size: size, trigger: animationTrigger)
        case .backward:
            AnimatedForwardLabel(size: size, trigger: animationTrigger)
                .scaleEffect(x: -1)
        default:
            Image(systemName: type.systemImageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

private extension PlayerButtonType {
    var systemImageName: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .backward: "backward.fill"
        case .forward: "forward.fill"
        }
    }
}

/// A forward/back "double triangle" glyph that morphs its two triangles into one as it bounces,
/// like Apple Music's skip buttons.
struct AnimatedForwardLabel: View {
    let size: CGFloat
    var trigger: PlayerButtonTrigger
    var animationDuration: Double = 0.3
    @State private var animationTrigger: Bool = true
    @State private var bouncing: Bool = false

    var body: some View {
        ForwardLabelAnimationWrapper(size: size, linear: !bouncing, progress: animationTrigger ? 0 : 1)
            .onChange(of: trigger) {
                switch trigger {
                case let .one(bouncing): self.bouncing = bouncing
                case let .another(bouncing): self.bouncing = bouncing
                }
                withAnimation(.linear(duration: animationDuration * 0.9)) {
                    animationTrigger.toggle()
                } completion: {
                    animationTrigger.toggle()
                }
            }
    }
}

private struct ForwardLabel: View {
    let size: CGFloat
    var linear: Bool = false
    var progress: Double
    let sideFraction = 0.3

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                gliph
                    .padding(.leading, leftOffset)
                    .opacity(progress)

                gliph
                    .frame(width: size / 2)

                gliph
                    .frame(width: rightWidth)
                    .padding(.trailing, rightOffset)
                    .opacity(1 - progress)
            }
        }
        .frame(width: width, height: size)
    }

    var side: CGFloat { size * sideFraction }
    var width: CGFloat { size + side * 2 }

    var leftOffset: CGFloat {
        min(sideFraction, progress) * size
            + (1 - leftGrowthProgress) * side
            + rightProtrusionProgress * side
    }

    var rightOffset: CGFloat {
        max(0, sideFraction - progress) * size + rightShrinkProgress * side
    }

    var rightWidth: CGFloat {
        lerp(0, size / 2, 1 - scaleProgress)
    }

    var scaleProgress: Double {
        max(0, (progress - sideFraction) / (1.0 - sideFraction))
    }

    var leftGrowthProgress: Double {
        let progress = min(1, progress / sideFraction)
        return linear ? progress : sqrt(progress)
    }

    var linearRightShrinkProgress: Double {
        max(0, scaleProgress - (1 - sideFraction * 2)) / sideFraction / 2
    }

    var rightShrinkProgress: Double {
        linear ? linearRightShrinkProgress : linearRightShrinkProgress * linearRightShrinkProgress
    }

    var rightProtrusionProgress: Double {
        linearRightShrinkProgress - rightShrinkProgress
    }

    var gliph: some View {
        Image(systemName: "play.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private struct ForwardLabelAnimationWrapper: View, Animatable {
    let size: CGFloat
    let linear: Bool
    var progress: Double

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        ForwardLabel(size: size, linear: linear, progress: progress.clamped(to: 0 ... 1))
    }
}
