import SwiftUI

struct PanGesture: UIGestureRecognizerRepresentable {
    var onChange: (Value) -> Void
    var onEnd: (Value) -> Void
    /// Tags this instance's recognizer so an ancestor `deferring` to the same name will wait for
    /// it to fail before beginning — set on the queue's reorder handle.
    var priorityName: String? = nil
    /// Makes this instance's recognizer require any recognizer tagged `priorityName` to fail
    /// first, via a real `UIGestureRecognizerDelegate` — `UIGestureRecognizerRepresentable`
    /// itself exposes no such customization point. Set on the whole-player drag-to-dismiss
    /// gesture so it defers to the reorder handle.
    var deferring: String? = nil

    static let reorderHandleTag = "com.mmusic.playerQueue.reorderHandle"

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(deferring: deferring)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.name = priorityName
        if deferring != nil { recognizer.delegate = context.coordinator }
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        recognizer.name = priorityName
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        let state = recognizer.state
        let translation = recognizer.translation(in: recognizer.view).toSize()
        let velocity = recognizer.velocity(in: recognizer.view).toSize()
        let value = Value(translation: translation, velocity: velocity)

        if state == .began || state == .changed {
            onChange(value)
        } else {
            onEnd(value)
        }
    }

    struct Value {
        var translation: CGSize
        var velocity: CGSize
    }

    /// Implements the delegate side of `deferring`: makes the whole-player gesture require the
    /// tagged reorder-handle recognizer to fail before it can begin.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let deferring: String?

        init(deferring: String?) {
            self.deferring = deferring
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let deferring else { return false }
            return otherGestureRecognizer.name == deferring
        }
    }
}

private extension CGPoint {
    func toSize() -> CGSize {
        CGSize(width: x, height: y)
    }
}
