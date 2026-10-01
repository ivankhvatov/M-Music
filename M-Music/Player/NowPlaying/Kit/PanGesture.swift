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
    /// Fails this recognizer as soon as its movement becomes more vertical than horizontal,
    /// instead of letting it track — and its callbacks quietly ignore — a vertical drag. A plain
    /// `UIPanGestureRecognizer` still *claims* every such touch even when its own callback later
    /// no-ops for it, which is enough to make an enclosing `ScrollView` contend for the touch
    /// instead of simply scrolling. Set on the queue row's swipe-to-delete gesture, which only
    /// ever wants horizontal movement and otherwise sits on top of a vertically scrolling list.
    var requiresHorizontalMovement = false

    static let reorderHandleTag = "com.mmusic.playerQueue.reorderHandle"

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(deferring: deferring, requiresHorizontalMovement: requiresHorizontalMovement)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.name = priorityName
        if deferring != nil || requiresHorizontalMovement { recognizer.delegate = context.coordinator }
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

    /// Implements the delegate side of `deferring` and `requiresHorizontalMovement`.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let deferring: String?
        let requiresHorizontalMovement: Bool

        init(deferring: String?, requiresHorizontalMovement: Bool) {
            self.deferring = deferring
            self.requiresHorizontalMovement = requiresHorizontalMovement
        }

        /// Makes the whole-player gesture require the tagged reorder-handle recognizer to fail
        /// before it can begin.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let deferring else { return false }
            return otherGestureRecognizer.name == deferring
        }

        /// Backs `requiresHorizontalMovement`. UIKit calls this right as *this* recognizer's own
        /// internal threshold is about to commit it from `.possible` to `.began`, with
        /// `translation(in:)` already reflecting the real movement so far — the officially
        /// supported veto point for "don't actually begin." Returning false here fails the
        /// recognizer cleanly and hands the touch to the enclosing `ScrollView`'s own pan
        /// recognizer.
        ///
        /// This replaced an earlier attempt that tried to pre-empt UIKit from inside
        /// `touchesMoved` by failing the recognizer once a manual 8pt check saw vertical-dominant
        /// movement, calling `super.touchesMoved` otherwise. That raced UIKit's own (unrelated,
        /// smaller) internal begin-threshold: whichever threshold's logic concluded first won,
        /// which is why scrolling starting on a row worked unpredictably. `shouldBegin` has no
        /// such race — there's only one threshold (this recognizer's own) being evaluated here.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard requiresHorizontalMovement, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return abs(t.x) >= abs(t.y)
        }
    }
}

private extension CGPoint {
    func toSize() -> CGSize {
        CGSize(width: x, height: y)
    }
}
