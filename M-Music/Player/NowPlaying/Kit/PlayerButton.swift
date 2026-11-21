import SwiftUI

/// A circular playback control button that scales down and shows a translucent backing circle
/// while pressed, matching Apple Music's transport buttons.
struct PlayerButton<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.playerButtonConfig) var config
    @Environment(\.playerButtonSymbolTransitions) private var symbolTransitions
    @State private var showCircle = false
    @State private var pressed = false
    private let activity = AppActivity.shared
    private let onEnded: (() -> Void)?
    private let label: Content?

    init(label: (() -> Content)? = nil, onEnded: (() -> Void)? = nil) {
        self.label = label?()
        self.onEnded = onEnded
    }

    var body: some View {
        content
            // Built afresh each time the app comes back, and not just re-evaluated: an animation that
            // was running when the app left the screen — the press shrinking back, the highlight
            // fading, the symbol swapping, the skip glyph morphing — isn't always finished or
            // replayed on the way back, and the button is left standing in the middle of it. Its
            // state is already at rest then (`pressed` false, the symbol the final one), so nothing
            // changes to make SwiftUI draw it again, and it stays like that until the next press.
            // A new identity starts every layer at its resting value, whatever was left over.
            .id(activity.resumeCount)
            .onChange(of: activity.isActive) {
                // The press state goes at once too, on the way out, and with no animation: a press
                // the system cancelled by taking the app away never reaches `onEnded`.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    pressed = false
                    showCircle = false
                }
            }
    }

    private var content: some View {
        label
            .scaleEffect(pressed ? 0.9 : 1)
            .frame(width: config.size, height: config.size)
            .foregroundStyle(color)
            .background {
                // A separate, smaller circle rather than filling the whole `config.size` frame
                // (which is also the tap target) — that let the highlight read as oversized next
                // to the icon it's behind.
                Circle()
                    .fill(showCircle ? config.tint : .clear)
                    .frame(width: config.size * config.circleScale, height: config.size * config.circleScale)
            }
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
            // Not while the app isn't active either: that transition is played by the render layer,
            // which isn't running then, so a change made in the meantime (paused from the lock
            // screen, by the sleep timer) would be held back and play in front of the user on the way
            // back.
            .contentTransition(symbolTransitions && activity.isActive ? .symbolEffect(.replace) : .identity)
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
    /// Whether a symbol change (play <-> pause) animates with the replace transition. That
    /// transition is played by the render layer, so for a button that's currently hidden (the
    /// expanded chrome while collapsed, the mini player while expanded) it would be held back until
    /// the button next appears, and then play in front of the user — a stale symbol first, then the
    /// swap. Hidden buttons switch this off so they change instantly and are already right.
    @Entry var playerButtonSymbolTransitions = true
}

struct PlayerButtonConfig {
    let updateInterval: TimeInterval
    let size: CGFloat
    /// The pressed-state highlight circle's diameter, as a fraction of `size` (the tap target
    /// itself is unaffected).
    let circleScale: CGFloat
    let labelColor: Color
    let tint: Color
    let pressedColor: Color
    let disabledColor: Color

    init(
        updateInterval: TimeInterval = 0.1,
        size: CGFloat = 68,
        circleScale: CGFloat = 0.7,
        labelColor: Color = .init(UIColor.label),
        tint: Color = .init(UIColor.tintColor),
        pressedColor: Color = .init(UIColor.secondaryLabel),
        disabledColor: Color = .init(UIColor.tertiaryLabel)
    ) {
        self.updateInterval = updateInterval
        self.size = size
        self.circleScale = circleScale
        self.labelColor = labelColor
        self.tint = tint
        self.pressedColor = pressedColor
        self.disabledColor = disabledColor
    }
}
