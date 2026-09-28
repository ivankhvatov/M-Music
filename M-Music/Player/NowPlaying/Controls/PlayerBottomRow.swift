import SwiftUI

/// The row below the transport buttons: lyrics and queue toggles flanking a "more" button.
/// Display only for now — none of the buttons do anything yet.
struct PlayerBottomRow: View {
    var body: some View {
        HStack {
            PlayerBottomButton(symbol: "quote.bubble", isOn: false, alignment: .leading)
            Spacer(minLength: 0)
            PlayerBottomButton(symbol: "ellipsis", alignment: .center)
            Spacer(minLength: 0)
            PlayerBottomButton(symbol: "list.bullet", isOn: false, alignment: .trailing)
        }
    }
}

/// A glyph button in `PlayerBottomRow`. Off, it's a plain transparent-white symbol; on, the symbol
/// is knocked out of a transparent-white circle (so whatever's behind shows through it).
private struct PlayerBottomButton: View {
    let symbol: String
    var isOn = false
    var alignment: Alignment

    var body: some View {
        Button(action: {}) {
            glyph
                // Aligned within the tap target like the star/AirPlay buttons above, so the
                // outer two sit on the row's edges instead of `(44 - circle)/2` points in.
                .frame(width: 48, height: 48, alignment: alignment)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var glyph: some View {
        if isOn {
            Circle()
                .fill(Color.transparentWhite)
                .frame(width: Const.circleSize, height: Const.circleSize)
                .mask {
                    ZStack {
                        Rectangle()
                        symbolImage.blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
        } else {
            symbolImage
                .foregroundStyle(Color.transparentWhite)
                .frame(width: Const.circleSize, height: Const.circleSize)
        }
    }

    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.system(size: Const.symbolSize, weight: .medium))
    }

    enum Const {
        /// Diameter of the "on" circle — also the off state's frame, so toggling never shifts layout.
        static let circleSize: CGFloat = 38
        static let symbolSize: CGFloat = 21
    }
}
