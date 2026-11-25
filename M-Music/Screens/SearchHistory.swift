import Foundation

/// What the user opened or played from the search results, newest first, as `SearchItem.id`s
/// ("album-42"): only the ids are kept, so what the history shows is always the library's current
/// version of each item, and one that has since left the library simply isn't shown.
///
/// An actor, so the (small) reads and writes never run on the main actor; persisted in
/// `UserDefaults`, which is plenty for a few dozen short strings.
actor SearchHistoryStore {
    static let shared = SearchHistoryStore()

    /// How many items are remembered.
    static let limit = 30

    private let defaults: UserDefaults
    private let key: String
    private var ids: [String]

    init(defaults: UserDefaults = .standard, key: String = "search.history") {
        self.defaults = defaults
        self.key = key
        ids = defaults.stringArray(forKey: key) ?? []
    }

    /// The remembered ids, newest first.
    func recent() -> [String] { ids }

    /// Puts `id` at the front, whether or not it was there before.
    func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
        save()
    }

    func remove(_ id: String) {
        ids.removeAll { $0 == id }
        save()
    }

    func clear() {
        ids = []
        save()
    }

    private func save() {
        defaults.set(ids, forKey: key)
    }
}
