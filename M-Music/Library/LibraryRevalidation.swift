import Foundation

/// Decides whether a cached whole-library list (all albums / artists / songs) needs to be
/// re-downloaded, instead of every screen re-downloading, re-decoding and re-comparing the entire
/// list on every appearance — for a library of thousands of items that's dozens of sequential
/// requests plus a full JSON decode, and by far the most expensive part of opening a list.
///
/// Those three lists are all derived from the server's library scan, so the server's
/// `getScanStatus` `lastScan` timestamp is a one-request answer to "has anything changed since I
/// last synced?" A list is only re-downloaded when it has (or was never synced, or the caller
/// forces it with pull-to-refresh). If the server doesn't report `lastScan` — or the request
/// fails — it falls back to re-downloading at most once per `fallbackInterval`.
///
/// Deliberately not used for playlists: those are edited without any library scan, so `lastScan`
/// says nothing about them (and their list is a single cheap request anyway).
///
/// Known trade-off: things that change without a scan — stars or play counts changed from another
/// device — don't show up in these lists until a rescan, a forced refresh, or the fallback timer.
actor LibraryRevalidation {
    static let shared = LibraryRevalidation()

    enum List: String {
        case albums, artists, songs
    }

    struct Check {
        /// Whether the list should be re-downloaded.
        let needsRefetch: Bool
        /// The server's `lastScan` as of *this* check — pass it to `markSynced` after a
        /// successful fetch. Captured before fetching, not after, so a scan that finishes
        /// mid-fetch still triggers a refetch next time instead of being recorded as already seen.
        let token: String?
    }

    /// How long a list counts as fresh when the server gives us no `lastScan` to compare.
    static let fallbackInterval: TimeInterval = 10 * 60

    private static let defaultsPrefix = "libraryRevalidation."

    /// When each list was last synced *this process* — only consulted by the fallback timer.
    private var syncedAt: [String: Date] = [:]

    func check(_ list: List, client: SubsonicClient = .shared) async -> Check {
        guard let key = Self.key(for: list, client: client) else {
            return Check(needsRefetch: true, token: nil)
        }

        let status = try? await client.getScanStatus()
        if let status, let lastScan = status.lastScan, !lastScan.isEmpty {
            // Mid-scan, the library is in flux and `lastScan` is still the previous scan's.
            if status.scanning {
                return Check(needsRefetch: true, token: lastScan)
            }
            let stored = UserDefaults.standard.string(forKey: Self.defaultsPrefix + key)
            return Check(needsRefetch: stored != lastScan, token: lastScan)
        }

        if let last = syncedAt[key], Date().timeIntervalSince(last) < Self.fallbackInterval {
            return Check(needsRefetch: false, token: nil)
        }
        return Check(needsRefetch: true, token: nil)
    }

    /// Records a successful sync of `list` — whether or not the downloaded data turned out to
    /// differ from what was cached.
    func markSynced(_ list: List, token: String?, client: SubsonicClient = .shared) {
        guard let key = Self.key(for: list, client: client) else { return }
        syncedAt[key] = Date()
        if let token {
            UserDefaults.standard.set(token, forKey: Self.defaultsPrefix + key)
        }
    }

    /// Forgets everything — for when the cached library itself is wiped (`LibraryCacheDatabase.clearAll`),
    /// so a stale "already synced" token can't outlive the data it described.
    func reset() {
        syncedAt.removeAll()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Scoped to the server and user, so switching to a different server can never reuse a
    /// token recorded against another one.
    private static func key(for list: List, client: SubsonicClient) -> String? {
        guard let credentials = client.credentials else { return nil }
        return "\(list.rawValue)|\(credentials.baseURL.absoluteString)|\(credentials.username)"
    }
}
