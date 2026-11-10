import Foundation

/// Decides which Home covers to warm, off the main actor.
///
/// The views only *report*: a card appeared (`cardAppeared`), a carousel was built
/// (`carouselAppeared`), the app resumed (`resumed`). Each report is a lock and a dictionary write;
/// the work — finding the neighbours of a card, building their requests, de-duplicating them and
/// handing them to `ImageWarmer` — happens on a utility task, at most once per `interval`, and for
/// each carousel only the *latest* position counts. Before, every card that appeared did all of it
/// on the main thread, dozens of times a second during a fling.
final class HomeWarmCoordinator: @unchecked Sendable {
    static let shared = HomeWarmCoordinator()

    /// How long reports are collected before a pass runs.
    static let interval: Duration = .milliseconds(50)

    private let lock = NSLock()
    private var layout = HomeLayout.empty
    private var lastIndex: [String: Int] = [:]
    private var pendingCards: Set<String> = []
    private var pendingNear: Set<String> = []
    private var passScheduled = false

    /// The layout Home currently shows.
    func update(_ layout: HomeLayout) {
        lock.withLock { self.layout = layout }
    }

    /// The card at `index` of the carousel named `source` appeared.
    func cardAppeared(source: String, index: Int) {
        let schedule = lock.withLock { () -> Bool in
            lastIndex[source] = index
            pendingCards.insert(source)
            return markScheduled()
        }
        if schedule { startPass() }
    }

    /// The carousel was built — it's near the screen.
    func carouselAppeared(source: String) {
        let schedule = lock.withLock { () -> Bool in
            pendingNear.insert(source)
            return markScheduled()
        }
        if schedule { startPass() }
    }

    /// The app became active again: every carousel is warmed around where it was left.
    func resumed() {
        let schedule = lock.withLock { () -> Bool in
            pendingCards.formUnion(lastIndex.keys)
            return markScheduled()
        }
        if schedule { startPass() }
    }

    /// The first cards of every carousel, so scrolling down to one finds them ready.
    func warmAllCarousels() {
        Task.detached(priority: .utility) { [self] in
            let layout = lock.withLock { self.layout }
            let perCarousel = 4
            let requests = layout.requests(
                perCarousel: perCarousel, limit: perCarousel * (HomeCarouselKind.allCases.count + HomeContentSettings.randomGenreRange.upperBound)
            )
            guard !requests.isEmpty else { return }
            await ImageWarmer.shared.warmAhead(requests, source: "home")
        }
    }

    /// Tells `ImageWarmer` which covers Home opens with, for the next launch or resume.
    func rememberFirstScreen() {
        Task.detached(priority: .utility) { [self] in
            let requests = lock.withLock { layout }.rememberedRequests
            await ImageWarmer.shared.remember(.home, requests)
        }
    }

    // MARK: - Passes

    /// Call with the lock held.
    private func markScheduled() -> Bool {
        guard !passScheduled else { return false }
        passScheduled = true
        return true
    }

    private func startPass() {
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: Self.interval)
            await runPass()
        }
    }

    private func runPass() async {
        // Reports keep collecting while the screen is being scrolled; the pass runs once it settles.
        await ScrollActivity.shared.waitUntilIdle()
        let (layout, cards, near, indices) = lock.withLock { () -> (HomeLayout, Set<String>, Set<String>, [String: Int]) in
            defer {
                pendingCards = []
                pendingNear = []
                passScheduled = false
            }
            return (self.layout, pendingCards, pendingNear, lastIndex)
        }

        for source in cards {
            guard let carousel = layout.carousels.first(where: { $0.source == source }),
                  let index = indices[source] else { continue }
            await ImageWarmer.shared.warmAhead(Self.requests(around: index, in: carousel), source: source)
        }
        for source in near {
            guard let position = layout.carousels.firstIndex(where: { $0.source == source }) else { continue }
            await ImageWarmer.shared.warmAhead(Self.requestsOfNeighbors(of: position, in: layout), source: "home.nearby")
        }
    }

    // MARK: - Pure helpers

    /// The covers around `index` in `carousel`, nearest first.
    static func requests(around index: Int, in carousel: HomeCarouselModel) -> [ArtworkRequest] {
        ImageWarmer.neighbors(of: index, in: carousel.cards, count: ImageWarmer.carouselAheadCount).map(\.request)
    }

    /// The first covers of the carousels after and before the one at `position`.
    static func requestsOfNeighbors(of position: Int, in layout: HomeLayout) -> [ArtworkRequest] {
        [position + 1, position - 1, position + 2]
            .filter { layout.carousels.indices.contains($0) }
            .flatMap { layout.carousels[$0].cards.prefix(ImageWarmer.neighborCarouselCards).map(\.request) }
    }
}
