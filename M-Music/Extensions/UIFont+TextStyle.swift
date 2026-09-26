import UIKit

extension UIFont {
    /// The system font at `style`'s current preferred size, in the given weight — for APIs that
    /// take a `UIFont` rather than a SwiftUI `Font`, where there's no `.font(.title3).weight(...)`.
    static func preferred(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }
}
