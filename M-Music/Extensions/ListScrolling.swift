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

    func set(scrolling: Bool) {
        ScrollActivity.shared.set(scrolling: scrolling)
        if isScrolling != scrolling { isScrolling = scrolling }
    }
}

/// `content` — except in a row that first appears while its list is being scrolled, which shows
/// `placeholder` until the scroll stops, and `content` from then on. For a control that costs much
/// to build and can't be used mid-scroll anyway (a touch then only stops the scroll): the
/// placeholder must look just like it.
struct DeferredWhileScrolling<Content: View, Placeholder: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var isBuilt = false

    var body: some View {
        // A row that has its content doesn't read the scroll state again, so a new scroll
        // re-evaluates nothing in it.
        if isBuilt || !ScrollState.shared.isScrolling {
            content()
                .onAppear { isBuilt = true }
        } else {
            placeholder()
        }
    }
}
