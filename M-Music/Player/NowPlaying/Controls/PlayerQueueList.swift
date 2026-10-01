import SwiftUI

/// The up-next list shown in the expanded player while the queue toggle is on: every track after
/// the current one, as the same `SongRow`s the song lists use — on a transparent background, so the
/// player's backdrop shows through, and forced to the dark color scheme so the rows' primary/
/// secondary text reads as white over it.
struct PlayerQueueList: View {
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.displayScale) private var displayScale

    private let rowArtworkSize: CGFloat = 44
    private let rowSpacing: CGFloat = 12

    /// The id of the entry currently being dragged by its reorder handle, or nil when nothing is.
    @State private var draggedEntryID: String?
    /// The dragged row's own visual offset from its resting position: the gesture's raw
    /// translation minus whatever whole rows have already been committed into the queue — the
    /// residual, so the row tracks the finger smoothly instead of jumping at each swap.
    @State private var dragTranslation: CGFloat = 0
    /// The dragged entry's position in `upcoming` when the drag began — a fixed baseline that
    /// every callback recomputes the target index from, rather than chaining off the previous
    /// callback's own result. An earlier version corrected incrementally, per swap, and any small
    /// error in `rowHeight` compounded across a long drag; recomputing from this fixed origin
    /// plus the gesture's raw cumulative translation each time can't drift.
    @State private var dragOriginIndex: Int?
    /// The dragged entry's position as of the last commit to `player.queue` — tracked here rather
    /// than read back from `upcoming`'s own `index`, which reflects the *previous* commit only
    /// once SwiftUI re-renders. Gesture callbacks can fire faster than that render pass completes,
    /// so a callback reading `index` from `ForEach` could still see a stale position and re-issue
    /// a move from the wrong place — this state is updated synchronously instead.
    @State private var dragCurrentIndex: Int?
    /// One row's height plus the list's own row spacing, measured once from the first row and
    /// used to convert the drag's point offset into a row-count offset.
    @State private var rowHeight: CGFloat = 0
    /// Bumped every time the drag commits a swap, purely to drive the haptic below.
    @State private var reorderTick = 0
    /// The id of the entry whose swipe-to-delete button is currently revealed, if any — opening
    /// another row's closes this one, matching standard swipe-list behavior.
    @State private var openSwipeEntryID: String?

    var body: some View {
        VStack(spacing: 0) {
            // Outside the scroll view, so it stays put while the rows scroll under it.
            buttons
            ScrollView {
                VStack(spacing: 0) {
                    // Scrolls with the rows, so it leaves and enters with the list and needs no
                    // animation of its own.
                    header
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, entry in
                            queueRow(entry, index: index)
                        }
                    }
                }
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
                // Room for the edge fades (`FadeMask`), so the first and last rows can rest clear of them.
                .padding(.top, FadeMask.topFade)
                .padding(.bottom, FadeMask.bottomFade)
            }
            .scrollIndicators(.hidden)
            .mask { TopFade() }
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .medium), trigger: reorderTick)
    }

    /// One queue row, with the dragged row's highlight/shadow/scale and its own live offset —
    /// deliberately no `.animation(value:)` here: SwiftUI would replay it on every drag callback
    /// even though nothing but the offset itself changes between them, which is what made the
    /// row visibly chase its own position instead of tracking the finger directly. The few
    /// moments that should animate (pickup, a committed swap, the drop) wrap themselves in
    /// `withAnimation` instead.
    private func queueRow(_ entry: Entry, index: Int) -> some View {
        let isDragged = draggedEntryID == entry.id
        let songRow = SongRow(
            track: entry.track,
            rowArtworkSize: rowArtworkSize,
            displayScale: displayScale,
            showsReorderHandle: true,
            onReorderDragChanged: { reorderDragChanged($0, entry: entry, index: index) },
            onReorderDragEnded: { reorderDragEnded() }
        )
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isDragged ? 0.1 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -6)
        }
        .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 8, y: 4)
        .scaleEffect(isDragged ? 1.02 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if rowHeight == 0, height > 0 { rowHeight = height + rowSpacing }
        }
        // `.offset(y:)`/`.zIndex` are applied to the whole `SwipeToDeleteRow` below, not to
        // `songRow` directly: zIndex only lifts a view above its *siblings*, and trapping it
        // inside `SwipeToDeleteRow`'s own internal ZStack (button vs. content) meant it only
        // ever lifted the row above its own delete button, never above the *other* rows in
        // this LazyVStack — which is what let a dragged row render behind its neighbors.
        return SwipeToDeleteRow(
            id: entry.id,
            openEntryID: openSwipeEntryID,
            onOpen: { openSwipeEntryID = entry.id },
            onDelete: { deleteEntry(entry) },
            content: songRow
        )
        .offset(y: isDragged ? dragTranslation : 0)
        .zIndex(isDragged ? 1 : 0)
        // Leading, not trailing: deleting continues the row in the same direction it was just
        // swiped, instead of reversing into the delete button it came from.
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    /// Removes `entry` from the queue — called from the row's swipe-to-delete, whether tapped
    /// after a partial swipe or triggered by a full one. Looks the entry's index up fresh rather
    /// than trusting a captured one, since the same staleness risk as the reorder drag applies
    /// here too.
    private func deleteEntry(_ entry: Entry) {
        guard let index = upcoming.firstIndex(where: { $0.id == entry.id }) else { return }
        if openSwipeEntryID == entry.id { openSwipeEntryID = nil }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            player.removeFromQueue(atUpcomingIndex: index)
        }
    }

    /// Called continuously while a handle is dragged. `index` is this entry's live position in
    /// `upcoming` — it moves as swaps commit, since `upcoming` is derived straight from
    /// `player.queue` and this view re-renders whenever that changes.
    private func reorderDragChanged(_ value: PanGesture.Value, entry: Entry, index: Int) {
        guard rowHeight > 0 else { return }
        if draggedEntryID != entry.id {
            withAnimation(.easeOut(duration: 0.15)) {
                draggedEntryID = entry.id
            }
            dragOriginIndex = index
            dragCurrentIndex = index
        }
        guard let dragOriginIndex, let dragCurrentIndex else { return }

        let steps = (value.translation.height / rowHeight).rounded()
        let proposedIndex = min(max(dragOriginIndex + Int(steps), 0), upcoming.count - 1)

        if proposedIndex != dragCurrentIndex {
            withAnimation(.smooth(duration: 0.25)) {
                player.moveQueueItem(fromUpcomingIndex: dragCurrentIndex, toUpcomingIndex: proposedIndex)
            }
            self.dragCurrentIndex = proposedIndex
            reorderTick += 1
        }

        dragTranslation = value.translation.height - CGFloat(proposedIndex - dragOriginIndex) * rowHeight
    }

    private func reorderDragEnded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragTranslation = 0
            draggedEntryID = nil
        }
        dragOriginIndex = nil
        dragCurrentIndex = nil
    }

    /// The shuffle, repeat and non-stop buttons, sharing the row's width. They don't do anything yet.
    private var buttons: some View {
        HStack(spacing: 8) {
            HeaderButton(symbol: "shuffle")
            HeaderButton(symbol: "repeat")
            HeaderButton(symbol: "infinity")
        }
        .padding(.horizontal, NowPlayingLayout.cardPaddings)
        .padding(.top, 8)
    }

    /// "Up next", and where the queue came from beneath it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up next")
                .font(.headline)
                .foregroundStyle(.white)
            if let sourceName {
                Text("From \(sourceName)")
                    .font(.caption)
                    .foregroundStyle(Color.transparentWhite)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }

    /// Falls back to the current song's album when the queue wasn't started from a screen that
    /// named it (a lone song from a list, or a queue restored after a relaunch).
    private var sourceName: String? {
        player.queueSourceName ?? player.currentTrack?.album
    }

    /// A capsule-shaped, transparent gray button with a symbol, as wide as the row gives it.
    private struct HeaderButton: View {
        let symbol: String

        var body: some View {
            Button {} label: {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.transparentWhite)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.15), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }

    /// Fades the bottom `bottomFade` points of whatever it masks out, instead of cutting it off
    /// hard. Applied by `RegularChrome` to the list's *container* rather than to the list itself,
    /// so the fade stays put — ending exactly on the scrubber's top edge — while the list slides
    /// in or out behind it. Fixed-size pieces only, so nothing in it depends on the size it's
    /// given and it needn't be redrawn when that changes.
    struct BottomFade: View {
        var body: some View {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: FadeMask.bottomFade)
            }
        }
    }

    /// The top-edge counterpart, for the list's own mask.
    struct TopFade: View {
        var body: some View {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: FadeMask.topFade)
                Rectangle()
            }
        }
    }

    /// The fade sizes, shared with the list's padding so its first and last rows rest clear of them.
    enum FadeMask {
        static let topFade: CGFloat = 20
        static let bottomFade: CGFloat = 56
    }

    /// The tracks after the current one. Each gets an id from its track id plus how many times that
    /// track has already appeared above it (a queue can hold the same song twice) — stable as
    /// playback advances, which `SongRow` needs: it resolves its artwork URL once, in `init`.
    private var upcoming: [Entry] {
        guard let currentIndex = player.currentIndex, player.queue.indices.contains(currentIndex) else { return [] }
        var seen: [String: Int] = [:]
        return player.queue[(currentIndex + 1)...].map { track in
            let occurrence = seen[track.id.raw, default: 0]
            seen[track.id.raw] = occurrence + 1
            return Entry(id: "\(track.id.raw)#\(occurrence)", track: track)
        }
    }

    private struct Entry {
        let id: String
        let track: Child
    }

    /// Wraps a queue row with swipe-to-delete, styled after the system's own `List` swipe
    /// actions: swiping the row left reveals a capsule-shaped red delete button behind it.
    ///
    /// From 0% to 30% of the row's own width, the button holds a fixed size (30% of that width)
    /// while it fades and scales in; past 30% it switches to tracking the swipe directly,
    /// stretching to fill however much of the row has been revealed. The two phases meet exactly
    /// at 30% — the fixed size *is* the width the tracking phase would compute there too — so the
    /// handoff has no jump. Past 80%, a haptic fires once and the icon slides to the button's
    /// leading edge, matching the system's own "release to delete" cue; releasing there deletes
    /// immediately, same as a full swipe.
    ///
    /// Its own, purely horizontal `@State` — separate from the reorder drag's vertical state
    /// above — driven by a `PanGesture` with `requiresHorizontalMovement: true`, so it fails
    /// itself immediately for any drag that isn't horizontally dominant instead of continuing to
    /// track (and quietly ignore) it: a plain `UIPanGestureRecognizer`, even one whose callback
    /// no-ops for vertical movement, still *claims* the touch, which is what made the enclosing
    /// `ScrollView` fail to scroll unless a drag started on a row *without* this gesture (the
    /// "Up next" header). `deferring: PanGesture.reorderHandleTag` makes it additionally require
    /// the reorder handle's own gesture to fail first, so touching the handle can never also
    /// start a swipe reveal.
    private struct SwipeToDeleteRow<Content: View>: View {
        let id: String
        /// Some other row is currently open — closes this one if it was.
        let openEntryID: String?
        let onOpen: () -> Void
        let onDelete: () -> Void
        /// A precomputed value, not a `() -> Content` closure: this struct's own drag-tracking
        /// `@State` (`offset` and friends) re-runs `body` on essentially every touch-move event,
        /// and a closure would be called fresh each time — rebuilding `SongRow` (which signs a
        /// fresh artwork URL and resubscribes three `ObservableObject`s in its own `init`) on
        /// every single frame of the drag, confirmed 1:1 by instrumentation. None of that actually
        /// depends on this view's own offset, so there's nothing to rebuild: the caller already
        /// constructs it once per *its own* re-render, which only happens when the row's actual
        /// inputs (the track, whether it's the one being reorder-dragged, …) change.
        let content: Content

        /// The visible gap between the sliding row content and the revealed delete button.
        private let buttonGap: CGFloat = 10
        /// Below this drag distance, releasing snaps the row fully closed instead of leaving the
        /// button open.
        private let openThreshold: CGFloat = 24
        /// Drives the row and button settling open, closed, or into the delete button after a
        /// release — a visibly springy motion rather than a plain ease.
        private let settleAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.65)

        @State private var offset: CGFloat = 0
        /// The offset at the start of the current drag — a fixed baseline the same way the
        /// reorder drag's own origin index is, so this recomputes from raw translation each
        /// callback instead of drifting.
        @State private var dragStartOffset: CGFloat?
        /// The row's own width, measured once, so the button knows what "30% of the row" and
        /// "80% of the row" mean.
        @State private var rowWidth: CGFloat = 0
        /// Whether the icon is currently slid to the button's leading edge — i.e. whether the
        /// commit threshold was crossed as of the last drag callback. A real `@State`, mutated
        /// (inside an explicit, narrowly-scoped `withAnimation`) only at the exact moment
        /// `isPastCommitThreshold` flips, rather than an `.animation(value:)` modifier on that
        /// computed property: `isPastCommitThreshold` flickers back and forth on every callback
        /// while the finger sits near the 80% mark, and `.animation(value:)` starts a fresh
        /// animation on every one of those flips — overlapping with whichever one from the
        /// previous flip was still in flight, and sweeping in the width-tracking `.frame` below it
        /// (which changes on essentially every callback) along the way. That's what stalled the
        /// row for the better part of a second while dragging back through the threshold.
        /// Mutating this explicitly, only right at the crossing, keeps the animation scoped to
        /// just this one value and leaves the width changes alone entirely.
        @State private var showsLeadingIcon = false
        /// Bumped once when the drag first crosses the commit threshold, to drive the haptic below.
        @State private var commitHapticTick = 0

        /// Where the fade/scale phase hands off to the horizontal-stretch phase, and the width
        /// the button holds throughout the fade/scale phase itself.
        private var revealThreshold: CGFloat {
            rowWidth > 0 ? rowWidth * 0.3 : 74
        }
        private var isPastRevealThreshold: Bool { -offset >= revealThreshold }
        /// The button's current width — pinned at `revealThreshold` until the swipe passes it,
        /// then tracking the swipe 1:1, capped at the row's own width.
        private var revealedWidth: CGFloat {
            guard isPastRevealThreshold else { return revealThreshold }
            let cap = rowWidth > 0 ? rowWidth : revealThreshold
            return min(-offset, cap)
        }
        /// Fade/scale progress through the first phase: 0 at rest, 1 once at `revealThreshold`.
        private var appearProgress: CGFloat {
            guard revealThreshold > 0 else { return 0 }
            return min(max(-offset / revealThreshold, 0), 1)
        }
        private var isPastCommitThreshold: Bool {
            rowWidth > 0 && -offset >= rowWidth * 0.8
        }

        /// Shared by `content` and the delete button underneath it: once the row is open, a
        /// drag can legitimately start on either — see the button's own `.gesture` doc comment
        /// below for why both need it.
        private var swipeGesture: PanGesture {
            PanGesture(
                onChange: { value in
                    // Belt and suspenders: `requiresHorizontalMovement` fails the recognizer for
                    // a vertical-dominant drag, but its very first callback can still land before
                    // that takes effect.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if dragStartOffset == nil { dragStartOffset = offset }
                    let proposed = (dragStartOffset ?? 0) + value.translation.width
                    let maxDrag = rowWidth > 0 ? rowWidth : revealThreshold
                    offset = min(0, max(proposed, -maxDrag))
                    if isPastCommitThreshold != showsLeadingIcon {
                        if isPastCommitThreshold {
                            commitHapticTick += 1
                        }
                        withAnimation(.snappy(duration: 0.18)) {
                            showsLeadingIcon = isPastCommitThreshold
                        }
                    }
                },
                onEnd: { _ in
                    guard dragStartOffset != nil else { return }
                    dragStartOffset = nil
                    showsLeadingIcon = false
                    if isPastCommitThreshold {
                        onDelete()
                    } else if -offset > openThreshold {
                        withAnimation(settleAnimation) { offset = -revealThreshold }
                        onOpen()
                    } else {
                        withAnimation(settleAnimation) { offset = 0 }
                    }
                },
                deferring: PanGesture.reorderHandleTag,
                requiresHorizontalMovement: true
            )
        }

        var body: some View {
            ZStack(alignment: .trailing) {
                Button(action: onDelete) {
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(Color.red)
                            .frame(width: max(0, revealedWidth - buttonGap))
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsLeadingIcon ? .leading : .center)
                            .padding(.leading, showsLeadingIcon ? 22 : 0)
                            .frame(width: max(0, revealedWidth - buttonGap))
                    }
                    .frame(width: revealedWidth, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(appearProgress)
                .scaleEffect(0.6 + 0.4 * appearProgress, anchor: .trailing)
                .allowsHitTesting(offset < -0.5)
                // Once the row is open, this button covers the revealed portion of the row that
                // `content` no longer does (its hit-test rect shifted left along with it — see
                // that modifier below). Without the same gesture here too, a drag that *starts* on
                // that revealed area — the natural way to swipe an already-open row shut again —
                // never reaches a pan recognizer at all: it only ever sees the button's own tap
                // machinery, which doesn't track movement, so the row just sits there unresponsive
                // until the finger lifts. A plain tap still resolves fine alongside it: `.gesture`
                // here attaches a real `UIGestureRecognizer` straight to the button's hosting view,
                // a sibling of the one SwiftUI's own tap backs the button with — not SwiftUI's own
                // composed-gesture system, which *would* otherwise take exclusive priority over the
                // button. This one simply never exceeds its own movement threshold for a plain tap
                // and fails without claiming the touch, leaving the button's tap to fire normally.
                .gesture(swipeGesture)

                content
                    .contentShape(Rectangle())
                    .offset(x: offset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if rowWidth == 0, width > 0 { rowWidth = width }
                    }
                    .gesture(swipeGesture)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: commitHapticTick)
            .onChange(of: openEntryID) { _, newValue in
                if newValue != id, offset != 0 {
                    withAnimation(settleAnimation) { offset = 0 }
                }
            }
        }
    }
}
