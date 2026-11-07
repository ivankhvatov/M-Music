import Foundation

extension AlbumID3 {
    private func hasReleaseType(in candidates: Set<String>) -> Bool {
        (releaseTypes ?? []).contains { tag in
            candidates.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// Tagged "Single" (RELEASETYPE), in singular or plural form.
    var isSingleRelease: Bool { hasReleaseType(in: ["single", "singles"]) }

    /// Tagged "Album" or "EP" (RELEASETYPE), in singular or plural form.
    var isAlbumOrEPRelease: Bool { hasReleaseType(in: ["album", "albums", "ep", "eps"]) }

    /// Whether `self` and `other` are a Single and an Album/EP — different releases even when they
    /// share a title and artist, so never versions of one another. Only for an explicit tag on
    /// each side; an untagged release is never told apart this way.
    func isDistinctRelease(from other: AlbumID3) -> Bool {
        (isSingleRelease && other.isAlbumOrEPRelease) || (isAlbumOrEPRelease && other.isSingleRelease)
    }
}

extension Sequence where Element == AlbumID3 {
    /// Collapses multiple versions of the same release (same title and artist, different
    /// ALBUMVERSION tag — e.g. "Deluxe Edition", "Remastered") down to one representative per
    /// release: the untagged/plain version if one exists among them, otherwise whichever has the
    /// shortest version string. Backs the "Group release versions" setting.
    ///
    /// Exception: a release explicitly tagged "Single" is never collapsed together with one
    /// tagged "Album"/"EP" sharing the same title/artist — a single is a distinct release, not
    /// just another edition of the album or EP it happens to share a name with.
    func groupedByPreferredVersion() -> [AlbumID3] {
        let albums = Array(self)

        func baseKey(for album: AlbumID3) -> String {
            "\(album.name.lowercased())|\(album.artistId?.raw ?? album.artist?.lowercased() ?? "")"
        }

        // First pass: does each base (title, artist) group mix an explicit Single with an
        // explicit Album/EP? If so, that pairing is kept apart below rather than collapsed into
        // one representative.
        var hasSingleByBaseKey: [String: Bool] = [:]
        var hasAlbumOrEPByBaseKey: [String: Bool] = [:]
        for album in albums {
            let key = baseKey(for: album)
            if album.isSingleRelease { hasSingleByBaseKey[key] = true }
            if album.isAlbumOrEPRelease { hasAlbumOrEPByBaseKey[key] = true }
        }

        func groupKey(for album: AlbumID3) -> String {
            let base = baseKey(for: album)
            let conflicts = (hasSingleByBaseKey[base] ?? false) && (hasAlbumOrEPByBaseKey[base] ?? false)
            guard conflicts else { return base }
            return base + (album.isSingleRelease ? "|single" : "|other")
        }

        // Grouped via `Dictionary`, but the result order follows each group's first appearance in
        // `self` rather than the dictionary's own iteration order, which is unspecified and can
        // differ between calls with identical content — that made the carousel reshuffle on every
        // reopen.
        var order: [String] = []
        var groups: [String: [AlbumID3]] = [:]
        for album in albums {
            let key = groupKey(for: album)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(album)
        }
        return order.compactMap { key in
            let versions = groups[key]!
            return versions.first { $0.version == nil } ?? versions.min { ($0.version?.count ?? 0) < ($1.version?.count ?? 0) }
        }
    }
}
