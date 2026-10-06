import SwiftUI
import UIKit

/// Shows SwiftUI content in a view of UIKit's, filling the room it's given.
///
/// A panel that SwiftUI moves and fades is made of pieces it draws itself and pieces that are
/// views of UIKit's (a `List`'s collection view): the first follow its animation exactly, and
/// the others have the same animation done to them by UIKit, a frame apart — enough, at the
/// animation's fastest, for a row of buttons and the list under them to be a good many points
/// away from each other. Inside one UIKit view, everything the panel is made of is moved by
/// that view's animation alone, and stays where it is relative to the rest.
///
/// The content must be `Equatable`, so that it's only handed over again when it has changed —
/// not every time the view around it is evaluated, which is every frame of an animation.
struct PlatformHosted<Content: View & Equatable>: UIViewRepresentable {
    let content: Content

    final class Coordinator {
        var host: UIHostingController<Content>?
        var content: Content?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        // What's in it fills it, however it's sized; it's the room it's given that matters.
        host.sizingOptions = []
        context.coordinator.host = host
        context.coordinator.content = content
        return host.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.content != content else { return }
        context.coordinator.content = content
        context.coordinator.host?.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        return CGSize(width: width, height: height)
    }
}
