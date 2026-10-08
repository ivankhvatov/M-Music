import SwiftUI

/// The up-next list shown in the expanded player while the queue toggle is on: every track after
/// the current one, as the same `SongRow`s the song lists use — on a transparent background, so the
/// player's backdrop shows through, and forced to the dark color scheme so the rows' primary/
/// secondary text reads as white over it.
///
/// Swipe-to-delete is a real `List` with `.swipeActions` rather than a hand-rolled gesture: an
/// earlier hand-rolled version (tracking its own horizontal drag, drawing its own capsule button)
/// kept stalling the row's own animation mid-swipe for the better part of a second, from no single
/// fixable cause — chased through several rounds of gesture-priority and animation-scoping fixes
/// that each addressed a real, confirmed issue without ever actually stopping the freeze. `List`'s
/// own swipe actions are system code with none of that; the tradeoff is losing the old capsule
/// button's exact look (a plain red background with a leading icon instead). Drag-to-reorder is
/// kept exactly as it was — the custom always-visible handle below, not `List`'s own `.onMove`
/// (which only shows its handle in edit mode, and would've meant losing the handle entirely).
struct PlayerQueueList: View, Equatable {
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.displayScale) private var displayScale

    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.song
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
    /// How far each row the dragged one has passed is slid, to take the slot it left (or give up
    /// the one it's taken) — the cells stay where they are until the drop; see `reorderDragChanged`.
    @State private var bumpOffsets: [String: CGFloat] = [:]
    /// A copy of `upcoming` as it was when the drag began, `nil` when no drag is in progress.
    /// Decouples the drag from `player.queue` for the whole gesture, so `player.moveQueueItem` —
    /// which publishes to every `@ObservedObject` holder app-wide (including the whole expanded
    /// player's own chrome) and persists to disk — is called once per drag instead of once per row
    /// boundary crossed. See `reorderDragChanged`'s doc comment.
    @State private var draftOrder: [Entry]?
    /// Where each row last sat on screen, kept as it's reported (it's read once, when a drag
    /// begins; nothing is drawn from it), and where this view's own origin is.
    @State private var frames = FrameBox()
    /// Where the dragged row started, for as long as it is drawn — see `draggedRow`.
    @State private var dragStartFrame: CGRect?
    /// The dragged row is lifted — its background, shadow and size. Starts a moment after the row
    /// appears, so that the lifting is seen.
    @State private var isLifted = false
    /// The current track moving (see `player.queueAdvance`) changes the list in two steps, which
    /// these two follow for the latest such move. Ahead — a skip, the song ending, a tap on a
    /// row: the rows that moved out, the one that became current and any skipped before it, fade
    /// where they are, held on screen as they were (`player` has already moved on, and its
    /// `upcoming` no longer has them) — `fadingChainID`; then, `releasedAdvanceID`, the rest move up
    /// to the top. Back — the previous button — it's the reverse: first the rows
    /// move down (`releasedAdvanceID`), making room, and then the row that's back fades in
    /// (`arrivedAdvanceID`).
    ///
    /// Skipping on again while the rows are still fading carries on the same fade (a run of
    /// advances shares a `chainID`), and the rest move up once, when the skipping has paused.
    @State private var fadingChainID: Int?
    @State private var releasedAdvanceID: Int?
    @State private var arrivedAdvanceID: Int?
    /// `player.currentIndex`/`player.queue.count` as of pickup — compared against their live
    /// values at drop to detect whether something other than this drag (auto-advance to the next
    /// track, another screen's queue mutation) changed the queue out from under the frozen
    /// `draftOrder`. If so, the final commit in `reorderDragEnded` is skipped rather than risk
    /// moving the wrong track.
    @State private var dragOriginCurrentIndex: Int?
    @State private var dragSnapshotQueueCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Outside the list, so it stays put while the rows scroll under it.
            buttons
            List {
                // Scrolls with the rows, so it leaves and enters with the list and needs no
                // animation of its own.
                header
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(Array(displayedUpcoming.enumerated()), id: \.element.id) { index, entry in
                    QueueRowView(
                        entry: entry,
                        index: index,
                        rowArtworkSize: rowArtworkSize,
                        displayScale: displayScale,
                        isDragged: false,
                        isHidden: draggedEntryID == entry.id,
                        isSkipped: index < hiddenCount,
                        offsetY: bumpOffsets[entry.id] ?? 0,
                        onReorderDragChanged: { reorderDragChanged($0, entry: entry, index: index) },
                        onReorderDragEnded: { reorderDragEnded() },
                        onTap: { playEntry(entry) }
                    )
                    .equatable()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if rowHeight == 0, height > 0 { rowHeight = height + rowSpacing }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        frames.rows[entry.id] = frame
                    }
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteEntry(entry)
                        } label: {
                            Label("Delete", systemImage: "minus.circle.fill")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .contentMargins(.top, FadeMask.topFade, for: .scrollContent)
            .contentMargins(.bottom, FadeMask.bottomFade, for: .scrollContent)
            .mask { TopFade() }
        }
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { frames.origin = $0 }
        .overlay(alignment: .topLeading) { draggedRow }
        .sensoryFeedback(.impact(weight: .medium), trigger: reorderTick)
        .onChange(of: player.queueAdvance) { _, advance in
            guard let advance else { return }
            if advance.toIndex > advance.fromIndex {
                // The rows that moved out fade, and then the rest move up.
                fadingChainID = advance.chainID
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.smooth(duration: 0.35)) { releasedAdvanceID = advance.id }
                    player.releaseQueueAdvance(id: advance.id)
                }
            } else {
                // The rows move down, and then the row that's back fades in.
                withAnimation(.smooth(duration: 0.35)) { releasedAdvanceID = advance.id }
                player.releaseQueueAdvance(id: advance.id)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    arrivedAdvanceID = advance.id
                }
            }
        }
    }

    /// Shared by the header row and every queue row: `List`'s own default insets don't match the
    /// rest of the player's horizontal padding, and halving `rowSpacing` top/bottom on every row
    /// reproduces the old `LazyVStack(spacing:)` gap between consecutive rows exactly.
    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: rowSpacing / 2, leading: NowPlayingLayout.cardPaddings,
            bottom: rowSpacing / 2, trailing: NowPlayingLayout.cardPaddings
        )
    }

    /// `PlayerQueueList()` takes no initializer parameters and reads only its own `@ObservedObject`/
    /// `@State`/`@Environment` — nothing external that two instances could differ on — so any two
    /// instances are interchangeable from the outside. `.equatable()` at the call site
    /// (`RegularNowPlaying.swift`) relies on this to skip reconstructing this view (and rebuilding
    /// `upcoming`/the `List`) every time the enclosing `GeometryReader` reruns during the player's
    /// 0.3s expand/collapse morph — which happens every rendered frame, for a reason entirely
    /// unrelated to the queue's own contents. This doesn't block the view's own reactivity: its
    /// `@ObservedObject`/`@State` still invalidate and re-render it normally, independent of this
    /// check — exactly like `QueueRowView` below already relies on for per-row reconstruction during drag.
    static func == (lhs: Self, rhs: Self) -> Bool { true }

    /// One queue row, wrapped in `.equatable()` at its call site in `body` so SwiftUI skips
    /// calling `body` — and therefore skips constructing a fresh `SongRow`, whose `init` signs a
    /// brand new artwork URL every time (a random salt + MD5 + byte-wise hex formatting) — for
    /// every row except the one(s) whose `isDragged`/`offsetY` actually changed this frame.
    ///
    /// This used to be a plain function (`queueRow`) called inline from the `ForEach` closure.
    /// Since `dragTranslation`/`bumpOffsets` are `@State` on `PlayerQueueList` itself, every
    /// single drag callback (display-link frequency, 60-120Hz) invalidated the whole `body`,
    /// which meant that function — and the `SongRow` it built — ran fresh for *every visible
    /// row*, not just the dragged one: N rows × that signing work × every callback, independent
    /// of which row was actually moving. That's what spiked CPU to ~90% during a drag.
    ///
    /// Deliberately no `.animation(value:)` on the offset here: SwiftUI would replay it on every
    /// drag callback even though nothing but the offset itself changes between them, which is
    /// what made the row visibly chase its own position instead of tracking the finger directly.
    /// The few moments that should animate (pickup, a committed swap, the drop) wrap themselves
    /// in `withAnimation` instead, back where the state changes.
    private struct QueueRowView: View, Equatable {
        let entry: Entry
        let index: Int
        let rowArtworkSize: CGFloat
        let displayScale: CGFloat
        let isDragged: Bool
        /// Takes its place in the list without showing: the row being dragged is drawn on top of
        /// the list, not in it.
        var isHidden = false
        let isSkipped: Bool
        let offsetY: CGFloat
        /// Whether it comes and goes with the list's own transition — not the copy drawn over it.
        var hasTransition = true
        let onReorderDragChanged: (PanGesture.Value) -> Void
        let onReorderDragEnded: () -> Void
        let onTap: () -> Void

        var body: some View {
            SongRow(
                track: entry.track,
                rowArtworkSize: rowArtworkSize,
                displayScale: displayScale,
                showsReorderHandle: true,
                onReorderDragChanged: onReorderDragChanged,
                onReorderDragEnded: onReorderDragEnded,
                onTap: onTap,
                showsPlayingIndicator: false
            )
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isDragged ? 0.1 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -6)
            }
            .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 8, y: 4)
            .scaleEffect(isDragged ? 1.02 : 1)
            .offset(y: offsetY)
            // Only ever changes on its own, in a tap's jump: the skipped rows fade out in place.
            .opacity(isSkipped || isHidden ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: isSkipped)
            // Leading, not trailing: deleting continues the row in the same direction it was
            // just swiped, instead of reversing into the delete button it came from.
            .transition(hasTransition ? .opacity.combined(with: .move(edge: .leading)) : .identity)
        }

        /// Explicit, not synthesized — the two closures aren't `Equatable`, so Swift can't derive
        /// conformance here regardless. `index` is included even though it never affects what's
        /// drawn: it's captured inside `onReorderDragChanged` as the drag's origin baseline, and
        /// the only way that capture refreshes is `body` actually re-running. A row displaced by
        /// some *other* row's drag (every row strictly between the drag's start and end slot
        /// shifts, since `moveQueueItem` is a remove+insert) must compare unequal here, or a drag
        /// started on it later would compute its swap target from a stale index.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.entry.id == rhs.entry.id
                && lhs.index == rhs.index
                && lhs.isDragged == rhs.isDragged
                && lhs.isHidden == rhs.isHidden
                && lhs.isSkipped == rhs.isSkipped
                && lhs.offsetY == rhs.offsetY
                && lhs.rowArtworkSize == rhs.rowArtworkSize
                && lhs.displayScale == rhs.displayScale
        }
    }

    /// Plays `entry`, from a tap on its row. The tracks between the current one and it are
    /// skipped, and leave the list like any track that's moved on (see `PlayerManager.playUpcoming`
    /// and `heldAdvance`). Looks the entry's index up fresh, for the same reason as `deleteEntry`.
    private func playEntry(_ entry: Entry) {
        guard draggedEntryID == nil, let index = upcoming.firstIndex(where: { $0.id == entry.id }) else { return }
        player.playUpcoming(atUpcomingIndex: index)
    }

    /// Removes `entry` from the queue — called from the row's swipe-to-delete action. Looks the
    /// entry's index up fresh rather than trusting a captured one, since the same staleness risk
    /// as the reorder drag applies here too.
    private func deleteEntry(_ entry: Entry) {
        guard let index = upcoming.firstIndex(where: { $0.id == entry.id }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            player.removeFromQueue(atUpcomingIndex: index)
        }
    }

    /// Called continuously while a handle is dragged. `index` is this entry's position in the list,
    /// which stays as it was when the drag began — `player.queue` isn't touched until the drag
    /// ends (see `reorderDragEnded`).
    ///
    /// This used to call `player.moveQueueItem` on every swap — once per row boundary crossed.
    /// For a drag that crosses many rows, that meant many `@Published` publishes (fanning out to
    /// every view holding `PlayerManager.shared` as an `@ObservedObject` app-wide, including the
    /// whole expanded player's own chrome, which wraps this very list) and many `persistState()`
    /// calls (each spinning up a new `Task` + actor hop to `QueueStore`) — fixed costs per swap
    /// that scaled directly with how many rows one continuous drag passed over, which is what
    /// kept CPU spiking on a long drag even after per-callback costs were already fixed. The net
    /// effect of N sequential "move the dragged entry from its current slot to the next" swaps is
    /// mathematically identical to one "move from the original origin to the final slot" — the
    /// dragged element is always the same tracked identity, and removing/reinserting one element
    /// never reorders the others relative to each other — so the real commit now happens exactly
    /// once, in `reorderDragEnded`, regardless of how many rows the drag crosses. Every swap here
    /// instead only changes where the rows it passes are drawn, which has no `@Published` side
    /// effects at all.
    private func reorderDragChanged(_ value: PanGesture.Value, entry: Entry, index: Int) {
        guard rowHeight > 0, heldAdvance == nil else { return }
        if draggedEntryID != entry.id {
            // The list's row gives way to the dragged copy in the same frame, with nothing fading:
            // the copy is identical to it at that moment, and only then lifts (see `draggedRow`).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                draggedEntryID = entry.id
                isLifted = false
            }
            // Snapshot once, at pickup — every subsequent callback mutates this local copy
            // directly instead of re-deriving from `player.queue`. Also snapshot what the *real*
            // queue looked like, so `reorderDragEnded` can detect whether something else (the
            // current track finishing naturally, another screen editing the queue) changed it out
            // from under this frozen copy during the drag, and skip the final commit if so rather
            // than risk moving the wrong track.
            draftOrder = upcoming
            dragStartFrame = frames.rows[entry.id]
            dragOriginIndex = index
            dragCurrentIndex = index
            dragOriginCurrentIndex = player.currentIndex
            dragSnapshotQueueCount = player.queue.count
        }
        guard let dragOriginIndex, let dragCurrentIndex, let order = draftOrder else { return }

        let steps = (value.translation.height / rowHeight).rounded()
        let proposedIndex = min(max(dragOriginIndex + Int(steps), 0), order.count - 1)

        if proposedIndex != dragCurrentIndex {
            // The list itself isn't touched while the drag goes on: the rows the dragged one has
            // passed are slid into place by an offset each — one animated value that SwiftUI
            // carries on from wherever it is when the drag turns back, which moving their cells
            // (and making up for it with an offset) couldn't do: the offset would have had to
            // start from where the earlier slide had got to, which isn't known, and the row
            // jumped. The move is made once, at the drop (`reorderDragEnded`).
            var shifts: [String: CGFloat] = [:]
            for (position, other) in order.enumerated() where other.id != order[dragOriginIndex].id {
                if position > dragOriginIndex, position <= proposedIndex {
                    shifts[other.id] = -rowHeight
                } else if position < dragOriginIndex, position >= proposedIndex {
                    shifts[other.id] = rowHeight
                }
            }
            withAnimation(.smooth(duration: 0.25)) {
                bumpOffsets = shifts
            }

            self.dragCurrentIndex = proposedIndex
            reorderTick += 1
        }

        // The dragged row is drawn apart from the list, so wherever the list puts the cell it
        // leaves behind, the row itself follows the finger and nothing else.
        dragTranslation = value.translation.height
    }

    private func reorderDragEnded() {
        // The one real commit for the whole drag — see `reorderDragChanged`'s doc comment. Only
        // if the queue wasn't touched by anything else while this drag's `draftOrder` was frozen;
        // otherwise `dragOriginIndex`/`dragCurrentIndex` could point at the wrong tracks entirely,
        // so skip the commit rather than risk silently moving the wrong one.
        //
        // The rows' offsets go back to nothing in the same step as the move puts them where those
        // offsets have had them — so nothing seems to move.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let dragOriginIndex, let dragCurrentIndex, dragOriginIndex != dragCurrentIndex,
               player.currentIndex == dragOriginCurrentIndex, player.queue.count == dragSnapshotQueueCount {
                player.moveQueueItem(fromUpcomingIndex: dragOriginIndex, toUpcomingIndex: dragCurrentIndex)
            }
            draftOrder = nil
            bumpOffsets = [:]
        }
        // It settles into its slot — where the list already has its cell — and is then put back
        // into the list in its place.
        let slot = CGFloat((dragCurrentIndex ?? 0) - (dragOriginIndex ?? 0)) * rowHeight
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragTranslation = slot
            isLifted = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard draggedEntryID != nil, dragOriginIndex == nil else { return }
            draggedEntryID = nil
            dragStartFrame = nil
            dragTranslation = 0
        }
        dragOriginIndex = nil
        dragCurrentIndex = nil
        dragOriginCurrentIndex = nil
        dragSnapshotQueueCount = nil
    }

    /// The row being dragged, drawn over the list at the finger: where it started plus how far
    /// it has been dragged. Left in the list, the row was moved by the list (its cell takes the
    /// slot the row is dragged to) and by an offset made up of how far it was dragged less how far
    /// the cell had gone, and the two never landed in the same frame — for one or two frames, at
    /// the first swap of a fast drag, the row jumped back by most of a row's height.
    @ViewBuilder
    private var draggedRow: some View {
        if let id = draggedEntryID, let start = dragStartFrame, let entry = displayedUpcoming.first(where: { $0.id == id }) {
            QueueRowView(
                entry: entry,
                index: 0,
                rowArtworkSize: rowArtworkSize,
                displayScale: displayScale,
                isDragged: isLifted,
                isSkipped: false,
                offsetY: 0,
                hasTransition: false,
                onReorderDragChanged: { _ in },
                onReorderDragEnded: {},
                onTap: {}
            )
            .frame(width: start.width, height: start.height)
            .offset(x: start.minX - frames.origin.x, y: start.minY - frames.origin.y + dragTranslation)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.15)) { isLifted = true } }
        }
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

    /// The fade sizes, shared with the list's content margins so its first and last rows rest
    /// clear of them.
    enum FadeMask {
        static let topFade: CGFloat = 20
        static let bottomFade: CGFloat = 56
    }

    /// The tracks after the current one. Each gets an id from its track id plus how many times that
    /// track has already appeared above it (a queue can hold the same song twice) — stable as
    /// playback advances, which `SongRow` needs: it resolves its artwork URL once, in `init`.
    ///
    /// Built once per queue change (`queueVersion`) or step through the queue (`currentIndex`) and
    /// reused: it's O(queue length) — filtering, a per-track occurrence count and a string id each,
    /// on a queue that can hold thousands — and `body` reads it several times and re-runs on every
    /// `PlayerManager` publish (play/pause, buffering, star, ...), none of which touch the queue.
    private var upcoming: [Entry] {
        let version = player.queueVersion
        let index = player.currentIndex
        if let memo = Self.upcomingMemo, memo.version == version, memo.currentIndex == index {
            return memo.entries
        }
        let entries = Self.buildUpcoming(queue: player.queue, currentIndex: index)
        Self.upcomingMemo = (version, index, entries)
        return entries
    }

    private static var upcomingMemo: (version: Int, currentIndex: Int?, entries: [Entry])?

    private static func buildUpcoming(queue: [Child], currentIndex: Int?) -> [Entry] {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return [] }
        var seen: [String: Int] = [:]
        return queue[(currentIndex + 1)...].map { track in
            let occurrence = seen[track.id.raw, default: 0]
            seen[track.id.raw] = occurrence + 1
            return Entry(id: "\(track.id.raw)#\(occurrence)", track: track)
        }
    }

    /// `draftOrder` while a drag is in progress, so rows visually reorder in real time;
    /// `upcoming` otherwise.
    private var displayedUpcoming: [Entry] {
        draftOrder ?? heldRows ?? upcoming
    }

    /// The latest move of the current track ahead, until its rows have moved up too — not when a
    /// drag has the list's order in hand, or when the queue has since changed under it.
    private var heldAdvance: PlayerManager.QueueAdvance? {
        guard draftOrder == nil, let advance = player.queueAdvance, advance.id != releasedAdvanceID,
              advance.toIndex == player.currentIndex else { return nil }
        return advance
    }

    /// The rows as they were before that move.
    private var heldRows: [Entry]? {
        heldAdvance.map { Self.buildUpcoming(queue: player.queue, currentIndex: $0.fromIndex) }
    }

    /// How many rows, from the top, are out of sight: fading out, going forward; or not yet faded
    /// in, going back.
    private var hiddenCount: Int {
        guard draftOrder == nil, let advance = player.queueAdvance, advance.toIndex == player.currentIndex else { return 0 }
        if advance.toIndex > advance.fromIndex {
            return heldAdvance != nil && advance.chainID == fadingChainID ? advance.toIndex - advance.fromIndex : 0
        }
        return advance.id == releasedAdvanceID && advance.id != arrivedAdvanceID ? advance.fromIndex - advance.toIndex : 0
    }

    private struct Entry {
        let id: String
        let track: Child
    }
}

/// Positions reported by views, read when they're needed — held in a reference so that reporting
/// one doesn't redraw anything.
private final class FrameBox {
    var rows: [String: CGRect] = [:]
    var origin: CGPoint = .zero
}
