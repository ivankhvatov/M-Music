import SwiftUI
import UIKit

enum NowPlayingLayout {
    static let compactHeight: CGFloat = 48
    static let cardPaddings: CGFloat = 32

    static var safeAreaInsets: EdgeInsets {
        MainActor.assumeIsolated {
            EdgeInsets(UIApplication.shared.keyWindow?.safeAreaInsets ?? .zero)
        }
    }
}

extension EdgeInsets {
    init(_ insets: UIEdgeInsets) {
        self.init(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
}

extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

extension UIScreen {
    static var deviceCornerRadius: CGFloat {
        main.value(forKey: "_displayCornerRadius") as? CGFloat ?? 0
    }

    static var hairlineWidth: CGFloat {
        1 / main.scale
    }

    static var size: CGSize { main.bounds.size }
}

extension CGFloat {
    /// Snaps to whole points. `.onGeometryChange`-reported values can carry sub-point
    /// floating-point jitter frame to frame even when nothing visually moved — comparing those
    /// directly with `!=` before writing to `@State` never dedupes, which turns a "write only on
    /// real change" guard into an unconditional write and reintroduces the exact re-render loop
    /// the guard was meant to prevent. Round first, then compare.
    var roundedToPoint: CGFloat { rounded() }
}

extension CGRect {
    var roundedToPoint: CGRect {
        CGRect(x: origin.x.roundedToPoint, y: origin.y.roundedToPoint, width: size.width.roundedToPoint, height: size.height.roundedToPoint)
    }
}
