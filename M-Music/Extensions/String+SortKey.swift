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
