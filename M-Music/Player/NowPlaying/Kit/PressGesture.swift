import SwiftUI

private struct PressGesture: ViewModifier {
    @GestureState private var startTimestamp: Date?
    /// The loop that calls `onPressing` while a press is active — started when the press begins
    /// and cancelled when it ends. Previously this was a `Timer.publish(...).autoconnect()` held
    /// in `@State` and observed with `.onReceive`, which ticks (and makes SwiftUI process an
    /// update for) every `interval` seconds for as long as the view exists, pressed or not: with
    /// a handful of player buttons mounted at all times, that was several dozen main-thread
    /// updates a second while the app sat idle.
    @State private var pressingTask: Task<Void, Never>?
    private let interval: TimeInterval
    private var onPressed: () -> Void
    private var onPressing: (TimeInterval) -> Void
    private var onEnded: () -> Void

    init(
        interval: TimeInterval,
        onPressed: @escaping () -> Void,
        onPressing: @escaping (TimeInterval) -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.interval = interval
        self.onPressed = onPressed
        self.onPressing = onPressing
        self.onEnded = onEnded
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($startTimestamp) { _, current, _ in
                        if current == nil {
                            onPressed()
                            current = Date()
                        }
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
            .onChange(of: startTimestamp) { _, newValue in
                pressingTask?.cancel()
                pressingTask = nil
                guard let start = newValue else { return }
                pressingTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        if Task.isCancelled { break }
                        onPressing(Date().timeIntervalSince(start))
                    }
                }
            }
            .onDisappear {
                pressingTask?.cancel()
                pressingTask = nil
            }
    }
}

extension View {
    func onPressGesture(
        interval: TimeInterval = 0.1,
        onPressed: @escaping () -> Void,
        onPressing: @escaping (TimeInterval) -> Void = { _ in },
        onEnded: @escaping () -> Void
    ) -> some View {
        modifier(PressGesture(interval: interval, onPressed: onPressed, onPressing: onPressing, onEnded: onEnded))
    }
}
