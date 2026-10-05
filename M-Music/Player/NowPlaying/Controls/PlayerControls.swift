import SwiftUI

/// The button rows of the expanded Now Playing screen — transport (with star and AirPlay), then
/// lyrics/more/queue — spread evenly through the space below the scrubber. The title, artist and
/// scrubber above them are `PlayerTrackInfo`, hosted by `RegularChrome`.
struct PlayerControls: View {
    @ObservedObject private var player = PlayerManager.shared
    /// What the player shows in place of the big artwork (toggled by the bottom row). With the queue
    /// or lyrics showing, the rows shrink to their natural height, leaving the rest of the space
    /// to the panel above.
    @Binding var panel: PlayerPanel
    /// The height of the gaps between the scrubber, the transport row and the bottom row as they
    /// are without the queue, where the two spacers share out whatever room is left. Measured then
    /// and held fixed while the queue shows — where the rows are otherwise pushed to their natural
    /// height — so toggling the queue or lyrics never changes the spacing between them.
    @State private var restGap: CGFloat = 0

    private var isCompact: Bool { panel != .artwork }

    var body: some View {
        // Fills whatever `RegularChrome` leaves below the track info; the two equal spacers make
        // the gaps above the transport row and between it and the bottom row the same size.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(minHeight: isCompact ? restGap : 0, maxHeight: isCompact ? restGap : .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !isCompact { restGap = height }
                }
            controlsRow
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
                .frame(minHeight: isCompact ? restGap : 0, maxHeight: isCompact ? restGap : .infinity)
            PlayerBottomRow(panel: $panel)
                .padding(.horizontal, NowPlayingLayout.cardPaddings + 18)
        }
        .frame(maxHeight: isCompact ? nil : .infinity)
    }
}

private extension PlayerControls {
    /// The star (favorite) and AirPlay buttons flank the transport buttons in one row — star on
    /// the leading edge, AirPlay on the trailing edge, both the same size — same as Apple Music.
    var controlsRow: some View {
        HStack {
            starButton
            Spacer(minLength: 0)
            // Tighter than the `width * 0.14` this used when it had the row to itself — with
            // star and AirPlay now sharing the row too, that spacing overflowed the available
            // width and pushed AirPlay off the visible edge entirely.
            PlayerButtons(spacing: 12)
            Spacer(minLength: 0)
            airPlayButton
        }
    }

    var starButton: some View {
        Button {
            player.toggleStarred()
        } label: {
            Image(systemName: player.isCurrentTrackStarred ? "star.fill" : "star")
                .font(.system(size: 22))
                .foregroundStyle(Color.transparentWhite)
                // Leading-aligned in its tap target rather than centered, so the glyph itself
                // sits on the row's edge — matching the track info's text — instead of `(44-20)/2`
                // points further in, with the extra tap area extending inward instead.
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(.rect)
        }
        .disabled(player.isRadio)
        .opacity(player.isRadio ? 0.3 : 1)
    }

    var airPlayButton: some View {
        AirPlayButton(size: 22)
            .foregroundStyle(Color.transparentWhite)
            .frame(width: 44, height: 44, alignment: .trailing)
            .contentShape(.rect)
    }
}
