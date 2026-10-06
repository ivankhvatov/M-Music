import SwiftUI

/// What the expanded player shows in place of its big artwork — set by the bottom row's toggles.
/// Only one at a time: the queue and the lyrics are mutually exclusive.
enum PlayerPanel: Equatable {
    /// Neither: the big artwork.
    case artwork
    /// The up-next list.
    case queue
    /// The song's lyrics.
    case lyrics
}

/// The full-screen expanded Now Playing layout's chrome — drag grip and playback controls — with
/// an invisible placeholder reserving the artwork's spot. Kept separate from the artwork itself
/// (see `RegularArtwork`) so `ExpandableNowPlaying` can swap the two independently: nesting a
/// `matchedGeometryEffect` view inside a `.transition()`-ed parent breaks that parent's own
/// removal animation (it cuts short instead of animating), which is what made this chrome vanish
/// instantly on collapse instead of fading out with the rest of the shrink.
struct RegularChrome: View {
    var size: CGSize
    var colors: [Color]
    var onCollapse: () -> Void
    var marqueesActive = true
    var marqueeRestartToken = 0
    /// What is showing instead of the big artwork, if anything — see `lowerRegion`.
    @Binding var panel: PlayerPanel
    /// The room a panel has once it's showing — see `lowerRegion`. 0 until first measured.
    @State private var panelHeight: CGFloat = 0
    /// Whether the queue list is mounted while hidden. It's mounted shortly after the player first
    /// appears, rather than when the queue is first toggled on, so building its rows doesn't
    /// stall the start of that animation.
    @State private var mountsQueueList = false
    /// Whether the (mounted) queue list is held at zero height. Once the queue has been shown,
    /// the list would otherwise stay at its full height — masked, transparent, and moved every
    /// frame of every expand/collapse — for as long as the player lives, which is what made
    /// those animations stutter from then on. Hidden at rest it's parked, exactly as it was
    /// before the queue was ever opened, and only sized up as the queue is turned on.
    @State private var parksQueueList = true
    /// Whether the lyrics view is mounted. Unlike the queue list it isn't built ahead of time —
    /// it needs the song's lyrics, which are fetched when it appears — but it's mounted, hidden,
    /// just before the lyrics are turned on (see `panelBinding`), and removed again once they've
    /// left, so it isn't carried through every expand and collapse.
    @State private var mountsLyrics = false

    /// With a panel showing, the artwork is small and beside the title instead of above it.
    private var isCompact: Bool { panel != .artwork }

    var body: some View {
        VStack(spacing: 12) {
            grip
            Color.clear
                .frame(height: RegularNowPlayingLayout.artworkHeight(for: size, compact: isCompact))
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size, compact: isCompact))
                .padding(.horizontal, RegularNowPlayingLayout.Const.horizontalPadding)
            lowerRegion
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
        .task(id: marqueesActive) {
            guard marqueesActive, !mountsQueueList else { return }
            try? await Task.sleep(for: .milliseconds(800))
            mountsQueueList = true
        }
        // Parks the queue list, and unmounts the lyrics, once they've finished leaving. Cancelled
        // (the id changes) if either is turned back on in the meantime.
        .task(id: panel) {
            guard (panel != .queue && !parksQueueList) || (panel != .lyrics && mountsLyrics) else { return }
            try? await Task.sleep(for: .seconds(Animation.playerQueueAnimationDuration + 0.15))
            guard !Task.isCancelled else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                if panel != .queue { parksQueueList = true }
                if panel != .lyrics { mountsLyrics = false }
            }
        }
    }

    /// Everything below the artwork placeholder, top to bottom: the title/artist, the queue list or
    /// lyrics, the scrubber, then the button rows.
    ///
    /// The same views are laid out in all modes, with different numbers, so toggling a panel
    /// animates as a move rather than a swap. Without a panel the title sits at its natural
    /// height, the panel has none, and the button rows spread through the space that's left. With
    /// one, the title is pulled up (by a negative bottom padding that cancels the space it took,
    /// plus an offset in `PlayerTrackTitle`) onto the artwork's row beside it, the panel takes all
    /// the room the button rows don't need, and those shrink to their natural height. Going from
    /// the queue to the lyrics (or back) leaves all that as it is and just swaps what's in the
    /// panel: the one leaving moves down and fades while the one arriving moves up and fades in.
    private var lowerRegion: some View {
        // The scrubber's gap to the title scales with the space available, hence the reader.
        GeometryReader { geometry in
            let spacing = geometry.size.height * 0.04
            VStack(spacing: 0) {
                PlayerTrackTitle(
                    isCompact: isCompact,
                    width: size.width,
                    marqueesActive: marqueesActive,
                    marqueeRestartToken: marqueeRestartToken
                )
                .padding(.bottom, isCompact ? -RegularNowPlayingLayout.queueTitleRise : spacing * 2)
                // Pinned to the top of this frame, which is itself pinned to the title's bottom
                // edge: the panel is carried up (and back down) rigidly with the title, at exactly
                // its speed, rising out from behind the scrubber below — whose top edge the clip
                // below cuts it off at — rather than being revealed in place by the artwork
                // shrinking away above it. (A move transition instead measured its distance
                // against the frame's own, still-growing height, so it lagged the title.)
                //
                // The panel is always its final height (`panelHeight`) and merely overflows
                // this frame while it's still growing, so the scroll view is never resized —
                // relaying out a UIKit scroll view and its rows every frame is what made the
                // toggle stutter.
                ZStack(alignment: .top) {
                    if mountsQueueList || panel == .queue {
                        PlayerQueueList()
                            .equatable()
                            .frame(
                                maxWidth: .infinity,
                                minHeight: listHeight,
                                maxHeight: queueListMaxHeight,
                                alignment: .top
                            )
                            .panelPlacement(isShowing: panel == .queue)
                    }
                    if mountsLyrics || panel == .lyrics {
                        PlayerLyricsView(width: size.width, panelHeight: panelHeight)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: panelHeight,
                                maxHeight: panelHeight > 0 ? panelHeight : .infinity,
                                alignment: .top
                            )
                            .panelPlacement(isShowing: panel == .lyrics)
                    }
                }
                // Full width even while empty, or the clip would grow out from the center as the
                // panel comes in and shrink back into it as it leaves.
                .frame(maxWidth: .infinity, maxHeight: isCompact ? .infinity : 0, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // The final height, which layout reports as soon as a panel is toggled on;
                    // only ever grown, so a value read mid-animation can't shrink the panel.
                    if isCompact, height > panelHeight + 0.5 { panelHeight = height }
                }
                // Clips the panel to this frame and fades its bottom edge (the top one is the
                // panel's own, so it travels with it). It's applied here, to the frame, rather
                // than inside the panel, so the fade is there while it slides in or out too.
                // The mask is a fixed size, bottom-aligned to the frame, so it only ever moves
                // instead of being redrawn at a new size every frame.
                .mask(alignment: .bottom) {
                    PlayerQueueList.BottomFade()
                        .frame(maxHeight: panelHeight > 0 ? panelHeight : .infinity)
                }
                // Reaches down over the empty top of the scrubber's frame (its bar sits a little
                // below it), so the fade ends right on the bar rather than a gap above it. A
                // negative padding, after the mask: the frame — and so the mask — gets that much
                // taller, the layout doesn't.
                .padding(.bottom, isCompact ? -RegularNowPlayingLayout.scrubberBarInset : 0)
                PlayerProgress(spacing: spacing)
                PlayerControls(panel: panelBinding)
            }
        }
    }

    /// The height the queue list is laid out at: its final height, or none while parked.
    private var listHeight: CGFloat {
        parksQueueList ? 0 : panelHeight
    }

    /// The most room the queue list is offered. While it's parked that's none, whatever else is
    /// showing in the (then tall) panel area, such as the lyrics: offered the whole area, the
    /// hidden list would be laid out at full height, and moved, every frame of every expand and
    /// collapse. Not even while the panel's height is still unknown — the list would then be
    /// resized to nothing as soon as it was, in the middle of the first toggle's animation.
    private var queueListMaxHeight: CGFloat {
        if parksQueueList { return 0 }
        return listHeight > 0 ? listHeight : .infinity
    }

    /// What the controls' queue and lyrics buttons set. Normally that's `panel` itself; but if
    /// the panel being turned on isn't ready — the queue list isn't mounted yet (it's built
    /// shortly after the player first opens, and a first tap can come before then or while it's
    /// still building) or is parked at zero height, or the lyrics aren't mounted — doing that in
    /// the same animated update would *insert* it, or grow it, already at its final place:
    /// there's nothing for its offset and fade to animate from, so the buttons, "Up next" header
    /// and rows just appeared while the title and artwork moved. So it's mounted and sized first,
    /// hidden and without animation, and the animated change starts a beat later, once it's
    /// there.
    private var panelBinding: Binding<PlayerPanel> {
        Binding(
            get: { panel },
            set: { newValue in
                let needsPreparing = switch newValue {
                case .queue: !mountsQueueList || parksQueueList
                case .lyrics: !mountsLyrics
                case .artwork: false
                }
                guard needsPreparing else {
                    panel = newValue
                    return
                }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    if newValue == .queue {
                        mountsQueueList = true
                        parksQueueList = false
                    } else {
                        mountsLyrics = true
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.playerQueueAnimation) { panel = newValue }
                }
            }
        )
    }

    private var grip: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(width: 70, height: 5)
            .padding(.vertical, 12)
            .contentShape(.rect)
            .onTapGesture(perform: onCollapse)
    }
}

private extension View {
    /// Where a panel's content sits while it's showing and while it isn't. The title travels its
    /// layout move plus its own offset (`queueTitleRise`); the panel, hung from the title's layout
    /// position, gets that offset too, so the two cover the same distance in the same time. It
    /// fades along with the move, rather than only being cut off at the scrubber.
    func panelPlacement(isShowing: Bool) -> some View {
        offset(y: isShowing ? 0 : RegularNowPlayingLayout.queueTitleRise)
            .opacity(isShowing ? 1 : 0)
            .allowsHitTesting(isShowing)
            .accessibilityHidden(!isShowing)
    }
}

/// The large expanded-state artwork alone, positioned via a placeholder-grip/trailing-spacer
/// VStack that mirrors `RegularChrome`'s own layout exactly (same spacing, same grip-sized first
/// child) so the two align pixel-for-pixel without duplicating layout constants by hand. See
/// `RegularChrome`'s doc comment for why the two are kept apart.
struct RegularArtwork: View {
    @ObservedObject private var player = PlayerManager.shared
    var size: CGSize
    var animationNamespace: Namespace.ID
    /// With the queue or lyrics showing, the artwork shrinks to a small square at the top left —
    /// the same view with different numbers, so the toggle animates as a shrink and move.
    var isCompact = false

    var body: some View {
        VStack(spacing: 12) {
            Color.clear
                .frame(width: 70, height: 5)
                .padding(.vertical, 12)
            artwork
                .padding(.vertical, RegularNowPlayingLayout.artworkVerticalPadding(for: size, compact: isCompact))
                .padding(.horizontal, isCompact ? NowPlayingLayout.cardPaddings : RegularNowPlayingLayout.Const.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
            Spacer(minLength: 0)
        }
        .padding(.top, NowPlayingLayout.safeAreaInsets.top)
        .padding(.bottom, NowPlayingLayout.safeAreaInsets.bottom)
    }

    /// The paused/playing shrink is expressed as this view's own size (fed into
    /// `matchedGeometryEffect`) rather than, as it was, a fixed-size box with inner padding —
    /// `matchedGeometryEffect` only ever interpolates the frame it's actually given, so a fixed
    /// outer frame with the shrink hidden inside as padding never took part in the expand/collapse
    /// handoff to `CompactArtwork`: collapsing snapped straight back to full size before the
    /// (unrelated, un-inset) compact frame took over, instead of shrinking smoothly into it.
    @ViewBuilder
    private var artwork: some View {
        // The paused shrink doesn't apply to the small queue-mode artwork.
        let small = !player.isPlaying && !isCompact
        let fullSide = RegularNowPlayingLayout.artworkHeight(for: size, compact: isCompact)
        let shrunkSide = fullSide - RegularNowPlayingLayout.Const.pausedInset * 2
        let softShadow = small || isCompact
        TrackArtworkView(url: player.artworkURL, cornerRadius: isCompact ? 6 : 10)
            .shadow(color: Color(.sRGBLinear, white: 0, opacity: small ? 0.13 : 0.33), radius: softShadow ? 3 : 8, y: softShadow ? 3 : 10)
            .matchedGeometryEffect(id: PlayerMatchedGeometry.artwork, in: animationNamespace)
            .frame(width: small ? shrunkSide : fullSide, height: small ? shrunkSide : fullSide)
            // Reserves the full, un-shrunk square regardless of `small`, so the smaller box stays
            // centered with even margins instead of the surrounding VStack reflowing around it.
            .frame(width: fullSide, height: fullSide)
            .animation(.smooth, value: player.isPlaying)
    }
}

enum RegularNowPlayingLayout {
    enum Const {
        static let horizontalPadding: CGFloat = 25
        /// How much the artwork shrinks (per side) while paused — see `RegularArtwork.artwork`.
        static let pausedInset: CGFloat = 48
        /// Side of the artwork's small top-left square while the queue is showing.
        static let queueArtworkSide: CGFloat = 60
    }

    /// Side of the artwork square — full-width normally, small with the queue or lyrics showing.
    static func artworkHeight(for size: CGSize, compact: Bool = false) -> CGFloat {
        compact ? Const.queueArtworkSide : size.width - Const.horizontalPadding * 2
    }

    static func artworkVerticalPadding(for size: CGSize, compact: Bool = false) -> CGFloat {
        compact ? 0 : (size.height < 700 ? 10 : 30)
    }

    /// How far right of its normal edge the title/artist start with the queue showing: past the
    /// artwork and a gap.
    static let queueTitleInset = Const.queueArtworkSide + 14

    /// How far below the top of the scrubber's 60pt frame its bar starts: the bar and the time
    /// labels under it (about 31pt together) are centered in that frame, leaving ~14pt above.
    static let scrubberBarInset: CGFloat = 14

    /// How far up the title/artist move with the queue showing: from just below the artwork's row
    /// (the artwork's height plus `RegularChrome`'s 12pt spacing) onto it.
    static let queueTitleRise = Const.queueArtworkSide + 12
}

extension Animation {
    /// The move between the big-artwork and queue layouts.
    static let playerQueueAnimationDuration: TimeInterval = 0.4
    static var playerQueueAnimation: Animation { .smooth(duration: playerQueueAnimationDuration) }
}
