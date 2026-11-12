import SwiftUI

/// The row below the transport buttons: lyrics and queue toggles flanking a "more" button.
/// The queue and lyrics toggles each replace the big artwork with their panel (see
/// `RegularChrome`); the two are mutually exclusive — `panel` can only be one of them — so turning
/// either on turns the other off. "More" opens a menu to go to the song's album or artist, add it
/// to a playlist, set a sleep timer (while one runs, the item shows what's left and asks whether to
/// stop it) or open its lyrics (which does nothing yet).
struct PlayerBottomRow: View {
    @Binding var panel: PlayerPanel
    /// The song the "Add to playlist" sheet is open for, and what went wrong adding it.
    @State private var songToAdd: Child?
    @State private var addError: String?
    /// Whether the "Set timer" sheet, or the "Stop the timer?" alert, is up.
    @State private var showsTimerSheet = false
    @State private var showsStopTimerAlert = false
    @ObservedObject private var sleepTimer = SleepTimer.shared

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
        .sheet(item: $songToAdd) { song in
            AddToPlaylistSheet(song: song) { playlist in addToPlaylist(song, playlist) }
        }
        .sheet(isPresented: $showsTimerSheet) {
            SetTimerSheet { seconds, completion in sleepTimer.start(seconds: seconds, completion: completion) }
        }
        .alert("Stop the timer?", isPresented: $showsStopTimerAlert) {
            Button("Stop", role: .destructive) { sleepTimer.stop() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't add the song to the playlist", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }

    /// Adds to the end of the playlist, after the sheet has closed — so a failure (offline, say) is
    /// reported here.
    private func addToPlaylist(_ song: Child, _ playlist: PlaylistSummary) {
        Task {
            do {
                try await PlaylistEditor.add(song, to: playlist)
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}

private extension PlayerBottomRow {
    /// "Set timer" — or, while the timer runs, what's left of it, which asks whether to stop it. Once the
    /// time is up and the song is being played to its end, "After this song" in its place.
    @ViewBuilder
    var timerButton: some View {
        if sleepTimer.isRunning {
            SleepTimerMenuItem(countdown: sleepTimer.countdown) { showsStopTimerAlert = true }
        } else if sleepTimer.isWaitingForSongEnd {
            Button { showsStopTimerAlert = true } label: { TimerMenuLabel(title: String(localized: "After this song")) }
        } else {
            Button("Set timer", systemImage: "timer") { showsTimerSheet = true }
        }
    }

    /// Where the song is from: its album, and the album's artist; then what else can be done with
    /// it. The ids are read when a button is tapped, so the menu doesn't follow the player's every
    /// tick.
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
            Button("Add to playlist", systemImage: "text.badge.plus") {
                songToAdd = PlayerManager.shared.currentTrack
            }
            timerButton
            Button("Open lyrics", systemImage: "quote.closing") {}
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

/// The menu's timer item while a timer runs: what's left, which stops the timer when tapped. It alone
/// follows the countdown, so as it ticks only this item's number changes, not the rest of the menu.
private struct SleepTimerMenuItem: View {
    @ObservedObject var countdown: SleepTimerCountdown
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimerMenuLabel(title: SleepTimer.formatted(TimeInterval(countdown.seconds)))
        }
    }
}

/// A timer item's label in the menu while a timer is active: its text beside the active symbol.
private struct TimerMenuLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: Self.activeSymbol)
        }
    }

    /// The timer symbol knocked out of a filled circle, as the lyrics and queue buttons draw
    /// themselves when on (`PlayerBottomGlyph`) — as a template image, so the menu tints it like
    /// its other symbols. The symbol is the size the menu draws its own symbols at (the inactive timer
    /// item's), so the circle grows around it.
    private static let activeSymbol: UIImage = {
        let pointSize: CGFloat = 17
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = UIImage(systemName: "timer", withConfiguration: configuration) else { return UIImage() }
        // The menu shows an image at 30 pt at most, so no bigger, or the symbol would shrink with it.
        let side: CGFloat = 30
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let frame = CGRect(
                x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: frame, blendMode: .destinationOut, alpha: 1)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
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
