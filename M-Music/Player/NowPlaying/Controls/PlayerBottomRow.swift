import SwiftUI

/// The row below the transport buttons: lyrics and queue toggles flanking a "more" button.
/// The queue and lyrics toggles each replace the big artwork with their panel (see
/// `RegularChrome`); the two are mutually exclusive — `panel` can only be one of them — so turning
/// either on turns the other off. "More" opens a menu to go to the song's album or artist.
struct PlayerBottomRow: View {
    @Binding var panel: PlayerPanel

    var body: some View {
        HStack {
            PlayerBottomButton(symbol: "quote.bubble", isOn: panel == .lyrics, alignment: .leading) {
                withAnimation(.playerQueueAnimation) { panel = panel == .lyrics ? .artwork : .lyrics }
            }
            Spacer(minLength: 0)
            moreMenu
            Spacer(minLength: 0)
            PlayerBottomButton(symbol: "list.bullet", isOn: panel == .queue, alignment: .trailing) {
                withAnimation(.playerQueueAnimation) { panel = panel == .queue ? .artwork : .queue }
            }
        }
    }
}

private extension PlayerBottomRow {
    /// Where the song is from: its album, and the album's artist. The ids are read when a button
    /// is tapped, so the menu doesn't follow the player's every tick.
    var moreMenu: some View {
        Menu {
            Button("Go to album", systemImage: "opticaldisc") {
                guard let albumID = PlayerManager.shared.currentTrack?.albumId?.raw else { return }
                AppNavigation.shared.open(.album(id: albumID))
            }
            Button("Go to artist", systemImage: AppRoute.artistSymbol) {
                guard let albumID = PlayerManager.shared.currentTrack?.albumId?.raw else { return }
                AppNavigation.shared.open(.artist(ofAlbum: albumID))
            }
        } label: {
            PlayerBottomGlyph(symbol: "ellipsis", isOn: false)
                .frame(width: 48, height: 48, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
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
            PlayerBottomGlyph(symbol: symbol, isOn: isOn)
                // Aligned within the tap target like the star/AirPlay buttons above, so the
                // outer two sit on the row's edges instead of `(44 - circle)/2` points in.
                .frame(width: 48, height: 48, alignment: alignment)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

}

/// The symbol of a `PlayerBottomRow` button, on or off.
private struct PlayerBottomGlyph: View {
    let symbol: String
    let isOn: Bool

    var body: some View {
        glyph
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
