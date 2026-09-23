import Foundation

extension Sequence where Element == AlbumID3 {
    /// Collapses multiple versions of the same release (same title and artist, different
    /// ALBUMVERSION tag — e.g. "Deluxe Edition", "Remastered") down to one representative per
    /// release: the untagged/plain version if one exists among them, otherwise whichever has the
    /// shortest version string. Backs the "Group release versions" setting.
    func groupedByPreferredVersion() -> [AlbumID3] {
        func key(for album: AlbumID3) -> String {
            "\(album.name.lowercased())|\(album.artistId?.raw ?? album.artist?.lowercased() ?? "")"
        }
        // Grouped via `Dictionary`, but the result order follows each group's first appearance in
        // `self` rather than the dictionary's own iteration order, which is unspecified and can
        // differ between calls with identical content — that made the carousel reshuffle on every
        // reopen.
        var order: [String] = []
        var groups: [String: [AlbumID3]] = [:]
        for album in self {
            let groupKey = key(for: album)
            if groups[groupKey] == nil {
                order.append(groupKey)
            }
            groups[groupKey, default: []].append(album)
        }
        return order.compactMap { groupKey in
            let versions = groups[groupKey]!
            return versions.first { $0.version == nil } ?? versions.min { ($0.version?.count ?? 0) < ($1.version?.count ?? 0) }
        }
    }
}
