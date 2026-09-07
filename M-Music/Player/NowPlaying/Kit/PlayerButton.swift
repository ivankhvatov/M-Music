import SwiftUI

/// A circular playback control button that scales down and shows a translucent backing circle
/// while pressed, matching Apple Music's transport buttons.
struct PlayerButton<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.playerButtonConfig) var config
    @State private var showCircle = false
    @State private var pressed = false
    private let onEnded: (() -> Void)?
    private let label: Content?

    init(label: (() -> Content)? = nil, onEnded: (() -> Void)? = nil) {
        self.label = label?()
        self.onEnded = onEnded
    }

    var body: some View {
        label
            .scaleEffect(pressed ? 0.9 : 1)
            .frame(width: config.size, height: config.size)
            .foregroundStyle(color)
            .background(showCircle ? config.tint : .clear)
            .clipShape(Ellipse())
            .scaleEffect(pressed ? 0.85 : 1)
            .contentShape(.circle)
            .onPressGesture(
                interval: config.updateInterval,
                onPressed: {
                    guard isEnabled else { return }
                    withAnimation {
                        showCircle = true
                        pressed = true
                    }
                },
                onEnded: {
                    guard isEnabled else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation { showCircle = false }
                    }
                    withAnimation { pressed = false }
                    onEnded?()
                }
            )
            .contentTransition(.symbolEffect(.replace))
    }
}

private extension PlayerButton {
    var color: Color {
        isEnabled ? (showCircle ? config.pressedColor : config.labelColor) : config.disabledColor
    }
}

extension View {
    func playerButtonStyle(_ config: PlayerButtonConfig) -> some View {
        environment(\.playerButtonConfig, config)
    }
}

extension EnvironmentValues {
    @Entry var playerButtonConfig = PlayerButtonConfig()
}

struct PlayerButtonConfig {
    let updateInterval: TimeInterval
    let size: CGFloat
    let labelColor: Color
    let tint: Color
    let pressedColor: Color
    let disabledColor: Color

    init(
        updateInterval: TimeInterval = 0.1,
        size: CGFloat = 68,
        labelColor: Color = .init(UIColor.label),
        tint: Color = .init(UIColor.tintColor),
        pressedColor: Color = .init(UIColor.secondaryLabel),
        disabledColor: Color = .init(UIColor.tertiaryLabel)
    ) {
        self.updateInterval = updateInterval
        self.size = size
        self.labelColor = labelColor
        self.tint = tint
        self.pressedColor = pressedColor
        self.disabledColor = disabledColor
    }
}
