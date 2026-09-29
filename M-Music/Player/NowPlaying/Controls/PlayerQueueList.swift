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
        return SongRow(
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
        .offset(y: isDragged ? dragTranslation : 0)
        .zIndex(isDragged ? 1 : 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if rowHeight == 0, height > 0 { rowHeight = height + rowSpacing }
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
}
