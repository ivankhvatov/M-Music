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
    /// A sibling row's own temporary offset while it's sliding into the slot the dragged row just
    /// vacated — see the doc comment in `reorderDragChanged` on why this exists instead of
    /// animating the swap's own data mutation.
    @State private var bumpOffsets: [String: CGFloat] = [:]
    /// A local copy of `upcoming`, live-reordered as the drag crosses row boundaries. `nil` when
    /// no drag is in progress, in which case the list falls back to `upcoming` directly. Decouples
    /// the row order shown on screen from `player.queue` for the whole gesture, so
    /// `player.moveQueueItem` — which publishes to every `@ObservedObject` holder app-wide
    /// (including the whole expanded player's own chrome) and persists to disk — is called once
    /// per drag instead of once per row boundary crossed. See `reorderDragChanged`'s doc comment.
    @State private var draftOrder: [Entry]?
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
                    let isDragged = draggedEntryID == entry.id
                    QueueRowView(
                        entry: entry,
                        index: index,
                        rowArtworkSize: rowArtworkSize,
                        displayScale: displayScale,
                        isDragged: isDragged,
                        offsetY: isDragged ? dragTranslation : (bumpOffsets[entry.id] ?? 0),
                        onReorderDragChanged: { reorderDragChanged($0, entry: entry, index: index) },
                        onReorderDragEnded: { reorderDragEnded() }
                    )
                    .equatable()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if rowHeight == 0, height > 0 { rowHeight = height + rowSpacing }
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
        .sensoryFeedback(.impact(weight: .medium), trigger: reorderTick)
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
        let offsetY: CGFloat
        let onReorderDragChanged: (PanGesture.Value) -> Void
        let onReorderDragEnded: () -> Void

        var body: some View {
            SongRow(
                track: entry.track,
                rowArtworkSize: rowArtworkSize,
                displayScale: displayScale,
                showsReorderHandle: true,
                onReorderDragChanged: onReorderDragChanged,
                onReorderDragEnded: onReorderDragEnded
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
            .zIndex(isDragged ? 1 : 0)
            // Leading, not trailing: deleting continues the row in the same direction it was
            // just swiped, instead of reversing into the delete button it came from.
            .transition(.opacity.combined(with: .move(edge: .leading)))
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
                && lhs.offsetY == rhs.offsetY
                && lhs.rowArtworkSize == rhs.rowArtworkSize
                && lhs.displayScale == rhs.displayScale
        }
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

    /// Called continuously while a handle is dragged. `index` is this entry's live position in
    /// `draftOrder` — it moves as swaps commit locally, without touching `player.queue` at all
    /// until the drag ends (see `reorderDragEnded`).
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
    /// instead mutates `draftOrder`, a local copy, which is cheap and has no `@Published` side
    /// effects at all.
    private func reorderDragChanged(_ value: PanGesture.Value, entry: Entry, index: Int) {
        guard rowHeight > 0 else { return }
        if draggedEntryID != entry.id {
            withAnimation(.easeOut(duration: 0.15)) {
                draggedEntryID = entry.id
            }
            // Snapshot once, at pickup — every subsequent callback mutates this local copy
            // directly instead of re-deriving from `player.queue`. Also snapshot what the *real*
            // queue looked like, so `reorderDragEnded` can detect whether something else (the
            // current track finishing naturally, another screen editing the queue) changed it out
            // from under this frozen copy during the drag, and skip the final commit if so rather
            // than risk moving the wrong track.
            draftOrder = upcoming
            dragOriginIndex = index
            dragCurrentIndex = index
            dragOriginCurrentIndex = player.currentIndex
            dragSnapshotQueueCount = player.queue.count
        }
        guard let dragOriginIndex, let dragCurrentIndex, var order = draftOrder else { return }

        let steps = (value.translation.height / rowHeight).rounded()
        let proposedIndex = min(max(dragOriginIndex + Int(steps), 0), order.count - 1)

        if proposedIndex != dragCurrentIndex {
            // The dragged row's own motion is 100% `dragTranslation`, never animated by this
            // commit — only ever written outside `withAnimation`, below — so it never has to
            // agree frame-to-frame with anything else: there's nothing for it to fight. What
            // needs to move smoothly here is only the *other* row(s) this swap displaces, and
            // those get their own, separate, single-purpose animation instead of trying to make
            // the swap's own data mutation animate correctly.
            //
            // Two things were tried first, and both fought `List` itself (a real
            // `UICollectionView` underneath, unlike the old `LazyVStack` this replaced):
            // committing the move on an animated transaction let `List`'s own cell-move animation
            // run on a separate timeline from `dragTranslation`'s, which didn't agree frame to
            // frame — the dragged row visibly jumped toward its old slot before snapping back.
            // Animating *both* the move and `dragTranslation` together kept them closer, but
            // `List`'s own move animation and a `withAnimation`-driven property are still two
            // different interpolations of the same motion, and over several rapid swaps those
            // small disagreements compounded into a visible shake.
            //
            // Committing the move with no animation at all (`disablesAnimations`) sidesteps
            // `List`'s own animation entirely — the cell snaps straight to its correct slot, in
            // the same frame `dragTranslation` compensates for it, so the dragged row never has
            // anything to disagree with. That leaves the *displaced* row snapping too, which is
            // what this makes up for: capture it by id before the commit, give it a one-off
            // `@State` offset sized to exactly cancel its own jump (so it renders unmoved for one
            // frame), then animate that back to 0 — one row, one self-contained SwiftUI
            // animation, nothing else driving or racing it.
            let displacedIDs = (min(dragCurrentIndex, proposedIndex) ... max(dragCurrentIndex, proposedIndex))
                .filter { $0 != dragCurrentIndex }
                .compactMap { order.indices.contains($0) ? order[$0].id : nil }
            let bumpMagnitude: CGFloat = proposedIndex > dragCurrentIndex ? rowHeight : -rowHeight

            let movedEntry = order.remove(at: dragCurrentIndex)
            order.insert(movedEntry, at: proposedIndex)

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                draftOrder = order
                for id in displacedIDs { bumpOffsets[id] = bumpMagnitude }
            }
            // `DispatchQueue.main.async`, not back-to-back in this same call: both writes above
            // and below happen synchronously, before SwiftUI's next render pass even runs — two
            // sequential writes to the same dictionary key in one run-loop tick collapse into the
            // single net change SwiftUI actually observes (here, 0 to 0, since the jumped value
            // never got rendered in between), so animating the second write animates nothing.
            // Deferring it to the next tick lets the jumped frame actually render first, so the
            // animation that follows has a real, observed "from" value to animate away from.
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.25)) {
                    for id in displacedIDs { bumpOffsets[id] = 0 }
                }
            }

            self.dragCurrentIndex = proposedIndex
            reorderTick += 1
        }

        dragTranslation = value.translation.height - CGFloat(proposedIndex - dragOriginIndex) * rowHeight
    }

    private func reorderDragEnded() {
        // The one real commit for the whole drag — see `reorderDragChanged`'s doc comment. Only
        // if the queue wasn't touched by anything else while this drag's `draftOrder` was frozen;
        // otherwise `dragOriginIndex`/`dragCurrentIndex` could point at the wrong tracks entirely,
        // so skip the commit rather than risk silently moving the wrong one.
        if let dragOriginIndex, let dragCurrentIndex, dragOriginIndex != dragCurrentIndex,
           player.currentIndex == dragOriginCurrentIndex, player.queue.count == dragSnapshotQueueCount {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                player.moveQueueItem(fromUpcomingIndex: dragOriginIndex, toUpcomingIndex: dragCurrentIndex)
                draftOrder = nil
            }
        } else {
            draftOrder = nil
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragTranslation = 0
            draggedEntryID = nil
        }
        dragOriginIndex = nil
        dragCurrentIndex = nil
        dragOriginCurrentIndex = nil
        dragSnapshotQueueCount = nil
        // bumpOffsets not cleared here: any bump from the last swap may still be mid-animation
        // toward 0, and clearing the dictionary outright would cut it off with an instant,
        // visible jump to 0 instead of letting it finish settling on its own — entries that
        // already reached 0 cost nothing left sitting in the dictionary.
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
    private var upcoming: [Entry] {
        guard let currentIndex = player.currentIndex, player.queue.indices.contains(currentIndex) else { return [] }
        var seen: [String: Int] = [:]
        return player.queue[(currentIndex + 1)...].map { track in
            let occurrence = seen[track.id.raw, default: 0]
            seen[track.id.raw] = occurrence + 1
            return Entry(id: "\(track.id.raw)#\(occurrence)", track: track)
        }
    }

    /// `draftOrder` while a drag is in progress, so rows visually reorder in real time;
    /// `upcoming` otherwise.
    private var displayedUpcoming: [Entry] {
        draftOrder ?? upcoming
    }

    private struct Entry {
        let id: String
        let track: Child
    }
}
