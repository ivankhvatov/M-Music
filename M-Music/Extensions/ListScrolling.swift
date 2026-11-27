import SwiftUI

extension View {
    /// Tells the app while this list or grid is scrolled: work nobody is waiting for — warming the
    /// screens its rows lead to, say — holds off until the scroll settles (`ScrollActivity`), and
    /// rows leave their costly controls until then (`DeferredWhileScrolling`).
    func reportsScrollActivity() -> some View {
        onScrollPhaseChange { _, phase in
            ScrollState.shared.set(scrolling: phase != .idle)
        }
        .onDisappear { ScrollState.shared.set(scrolling: false) }
    }
}

/// What a view watches to know whether a list is being scrolled — see `reportsScrollActivity()`.
@MainActor
@Observable
final class ScrollState {
    static let shared = ScrollState()
    private(set) var isScrolling = false

    /// How long a list must have been at rest before rows build what they left out: another
    /// flick often follows at once.
    nonisolated static let settleDelay: Duration = .milliseconds(100)
    /// How far apart rows then take their turns: one a frame.
    nonisolated static let turnSpacing: Duration = .milliseconds(20)

    @ObservationIgnored private var nextTurn = ContinuousClock.now

    func set(scrolling: Bool) {
        ScrollActivity.shared.set(scrolling: scrolling)
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        // Turns still waiting belong to the rest that just ended.
        if scrolling { nextTurn = .now }
    }

    /// Waits for the caller's turn to build something now that the list is at rest. All the rows
    /// on screen doing so at once stalled it for as long as several frames. Returns whether the
    /// turn came: not if the caller was cancelled or a scroll has started again.
    func waitForTurn() async -> Bool {
        let turn = max(ContinuousClock.now + Self.settleDelay, nextTurn)
        nextTurn = turn + Self.turnSpacing
        try? await Task.sleep(until: turn, clock: .continuous)
        return !Task.isCancelled && !isScrolling
    }
}

/// `content` — except in a row that first appears while its list is being scrolled, which shows
/// `placeholder` until some moments after the scroll stops (each such row in turn), and `content`
/// from then on. For a control that costs much to build and can't be used mid-scroll anyway (a
/// touch then only stops the scroll): the placeholder must look just like it.
struct DeferredWhileScrolling<Content: View, Placeholder: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var isBuilt = false
    @State private var isDeferred = false

    var body: some View {
        // A row that has its content doesn't read the scroll state again, so a new scroll
        // re-evaluates nothing in it.
        if isBuilt || (!isDeferred && !ScrollState.shared.isScrolling) {
            content()
                .onAppear { isBuilt = true }
        } else {
            placeholder()
                // A touch meant for the control, in the moment before it's there, mustn't reach
                // the row behind it.
                .contentShape(Rectangle())
                .onTapGesture {}
                .onAppear { isDeferred = true }
                .task(id: ScrollState.shared.isScrolling) {
                    guard !ScrollState.shared.isScrolling, await ScrollState.shared.waitForTurn() else { return }
                    isBuilt = true
                }
        }
    }
}
