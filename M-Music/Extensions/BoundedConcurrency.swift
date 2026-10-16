import Foundation

enum BoundedConcurrency {
    /// Runs `work` for every item with at most `limit` running at once, and returns the results in
    /// the items' order. The windowed version of a plain `withTaskGroup` over everything, which
    /// starts one task — and, for network work, one request — per item at the same instant.
    static func map<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        limit: Int,
        _ work: @escaping @Sendable (Item) async -> Result
    ) async -> [Result] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: items.count)
            var next = 0
            var running = 0
            while next < items.count || running > 0 {
                while next < items.count, running < max(1, limit) {
                    let index = next
                    let item = items[index]
                    group.addTask { (index, await work(item)) }
                    next += 1
                    running += 1
                }
                if let (index, result) = await group.next() {
                    results[index] = result
                    running -= 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
