import SwiftUI

/// The big back/play-pause/forward transport row.
struct PlayerButtons: View {
    @ObservedObject private var player = PlayerManager.shared
    let spacing: CGFloat
    let imageSize: CGFloat = 34
    @State private var backwardAnimationTrigger: PlayerButtonTrigger = .one(bouncing: false)
    @State private var forwardAnimationTrigger: PlayerButtonTrigger = .one(bouncing: false)

    var body: some View {
        HStack(spacing: spacing) {
            PlayerButton(
                label: {
                    PlayerButtonLabel(type: .backward, size: imageSize, animationTrigger: backwardAnimationTrigger)
                },
                onEnded: {
                    DispatchQueue.main.async {
                        backwardAnimationTrigger.toggle(bouncing: true)
                    }
                    player.previous()
                }
            )

            PlayerButton(
                label: { PlayerButtonLabel(type: player.isPlaying ? .pause : .play, size: imageSize) },
                onEnded: { player.togglePlayPause() }
            )

            PlayerButton(
                label: {
                    PlayerButtonLabel(type: .forward, size: imageSize, animationTrigger: forwardAnimationTrigger)
                },
                onEnded: {
                    DispatchQueue.main.async {
                        forwardAnimationTrigger.toggle(bouncing: true)
                    }
                    player.next()
                }
            )
        }
        .playerButtonStyle(.expandedPlayer)
    }
}

extension PlayerButtonConfig {
    static var expandedPlayer: Self {
        Self(
            circleScale: 0.8,
            labelColor: .white,
            tint: Color.white.opacity(0.3),
            pressedColor: .white
        )
    }
}
