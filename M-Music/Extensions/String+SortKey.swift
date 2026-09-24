import Foundation

extension String {
    /// Leading articles to ignore when sorting titles/artists, e.g. "The Beatles" sorts under "B".
    private static let sortingArticles: Set<String> = [
        "a", "an", "the",
        "der", "die", "das", "den", "dem", "des",
        "le", "la", "les",
        "el", "los", "las",
        "il", "lo", "gli", "i",
    ]

    /// This string with a leading article (if any) stripped, for use in sort comparisons.
    var sortKey: String {
        guard let spaceIndex = firstIndex(of: " ") else { return self }
        let firstWord = self[startIndex..<spaceIndex].lowercased()
        guard Self.sortingArticles.contains(firstWord) else { return self }
        return String(self[index(after: spaceIndex)...])
    }
}

extension Array {
    /// Sorts by `key` with `localizedStandardCompare`, computing each element's key exactly once.
    /// Sorting with the key computed inside the comparator instead (`sortKey` allocates a new
    /// string) redoes that work on both sides of every one of the O(n log n) comparisons — for a
    /// whole-library list, that's a lot of throwaway strings on the main thread.
    func sortedByLocalizedKey(ascending: Bool, key: (Element) -> String) -> [Element] {
        map { (key: key($0), element: $0) }
            .sorted { lhs, rhs in
                let comparison = lhs.key.localizedStandardCompare(rhs.key)
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            .map(\.element)
    }
}
