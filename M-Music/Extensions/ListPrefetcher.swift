import Foundation

/// Which rows of a scrolling list to have artwork ready for: mostly the ones ahead of the scroll.
///
/// It's told of each row that comes on screen (`onAppear`, the one thing a `List` reports
/// dependably), works out from that which way the list is moving and, every few rows, returns the
/// rows to warm (`ImageWarmer.warmAhead`), the most needed first.
@MainActor
final class ListPrefetcher {
    /// How many rows ahead of the scroll are warmed — about three screens of them.
    nonisolated static let ahead = 30
    /// And how many behind it, for a scroll that turns back.
    nonisolated static let behind = 6
    /// How many rows the list moves before the plan is made again.
    nonisolated static let stride = 4

    private var last: Int?
    /// 1 towards the end of the list, -1 towards its start.
    private var direction = 1
    /// Rows in a row that appeared the other way: one alone doesn't turn the plan round.
    private var contrary = 0
    private var planned: (index: Int, direction: Int, count: Int)?

    /// The row at `index`, of `count`, came on screen: the rows to warm now, or `nil` while the
    /// last plan still serves.
    func rows(appearing index: Int, of count: Int) -> [Int]? {
        defer { last = index }
        if let last, index != last {
            let step = index > last ? 1 : -1
            if abs(index - last) > Self.ahead {
                // A jump (to the top, say): nothing to tell the direction by yet.
                (direction, contrary) = (1, 0)
            } else if step == direction {
                contrary = 0
            } else {
                contrary += 1
                if contrary >= 2 { (direction, contrary) = (step, 0) }
            }
        }
        if let planned, planned.direction == direction, planned.count == count,
           abs(planned.index - index) < Self.stride {
            return nil
        }
        planned = (index, direction, count)
        return Self.plan(from: index, direction: direction, count: count)
    }

    /// The list's rows changed: the next one to appear makes a new plan.
    func reset() {
        (last, direction, contrary, planned) = (nil, 1, 0, nil)
    }

    /// The rows around `index` in the order they're needed: it, those ahead, then those behind.
    /// Near an end of the list, what one side has too few of goes to the other — so a direction
    /// guessed wrong at the top of a list, from the order its first rows happened to appear in,
    /// still has the rows below ready.
    nonisolated static func plan(from index: Int, direction: Int = 1, count: Int) -> [Int] {
        guard index >= 0, index < count else { return [] }
        let total = ahead + behind
        let inList = { (row: Int) in row >= 0 && row < count }
        let forward = (1...total).map { index + $0 * direction }.filter(inList)
        let backward = (1...total).map { index - $0 * direction }.filter(inList)
        let front = min(forward.count, max(ahead, total - backward.count))
        return [index] + forward.prefix(front) + backward.prefix(total - front)
    }
}
