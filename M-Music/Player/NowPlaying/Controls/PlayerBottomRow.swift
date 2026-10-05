import SwiftUI

/// The row below the transport buttons: lyrics and queue toggles flanking a "more" button.
/// The queue toggle reveals the up-next list (see `RegularChrome`); lyrics and "more" don't do
/// anything yet — lyrics just remembers whether it's on. The two toggles are mutually exclusive:
/// turning either on turns the other off, so at most one of them is ever on.
struct PlayerBottomRow: View {
    @Binding var showsQueue: Bool
    @State private var showsLyrics = false

    var body: some View {
        HStack {
            PlayerBottomButton(symbol: "quote.bubble", isOn: showsLyrics, alignment: .leading) {
                showsLyrics.toggle()
                if showsLyrics, showsQueue {
                    withAnimation(.playerQueueAnimation) { showsQueue = false }
                }
            }
            Spacer(minLength: 0)
            PlayerBottomButton(symbol: "ellipsis", alignment: .center) {}
            Spacer(minLength: 0)
            PlayerBottomButton(symbol: "list.bullet", isOn: showsQueue, alignment: .trailing) {
                withAnimation(.playerQueueAnimation) { showsQueue.toggle() }
            }
        }
        // Watched rather than done in the queue button's action: turning the queue on can be
        // deferred a beat (see `RegularChrome.queueButtonBinding`), so it isn't on yet when
        // the button is tapped.
        .onChange(of: showsQueue) {
            if showsQueue { showsLyrics = false }
        }
    }
}

/// A glyph button in `PlayerBottomRow`. Off, it's a plain transparent-white symbol; on, the symbol
/// is knocked out of a transparent-white circle (so whatever's behind shows through it).
private struct PlayerBottomButton: View {
    let symbol: String
    var isOn = false
    var alignment: Alignment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
