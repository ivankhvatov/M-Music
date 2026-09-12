import Foundation

extension Sequence where Element == AlbumID3 {
    /// Collapses multiple versions of the same release (same title and artist, different
    /// ALBUMVERSION tag — e.g. "Deluxe Edition", "Remastered") down to one representative per
    /// release: the untagged/plain version if one exists among them, otherwise whichever has the
    /// shortest version string. Backs the "Group release versions" setting.
    func groupedByPreferredVersion() -> [AlbumID3] {
        let groups = Dictionary(grouping: self) { album in
            "\(album.name.lowercased())|\(album.artistId?.raw ?? album.artist?.lowercased() ?? "")"
        }
        return groups.values.compactMap { versions in
            versions.first { $0.version == nil } ?? versions.min { ($0.version?.count ?? 0) < ($1.version?.count ?? 0) }
        }
    }
}
