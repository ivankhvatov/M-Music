import Foundation

/// One match in the library search: an artist, an album, a playlist or a song.
enum SearchItem: Identifiable, Sendable {
    case artist(ArtistID3)
    case album(AlbumID3)
    case playlist(PlaylistSummary)
    case song(Child)

    var id: String {
        switch self {
        case .artist(let artist): "artist-\(artist.id.raw)"
        case .album(let album): "album-\(album.id.raw)"
        case .playlist(let playlist): "playlist-\(playlist.id.raw)"
        case .song(let song): "song-\(song.id.raw)"
        }
    }
}

/// What a search found, best first, and the thumbnail each row of it shows (`requests[i]` is
/// `items[i]`'s) — built here, off the main actor, so the screen can gate on and warm them without
/// deriving anything itself.
struct SearchOutcome: Sendable {
    var items: [SearchItem]
    var requests: [ArtworkRequest]
}

/// The library search, off the main actor: it holds the artists, albums, playlists and songs, each
/// with its searchable text folded (case and diacritics) **once**, when the list arrives — not on
/// every keystroke, which is what an `localizedCaseInsensitiveContains` per item did — and finds
/// matches by plain string comparison on those.
///
/// A query that contains the previous one (the user typed another letter) can only match what the
/// previous one matched, so it scans that set instead of the whole library.
///
/// Nothing here is observable or main-actor: the screen `await`s `search` from a task it can
/// cancel, which makes the scan stop early (it checks between batches).
actor SearchEngine {
    /// One searchable item. `name` and `other` (the artist of an album or song, the owner of a
    /// playlist) are folded.
    private struct Entry: Sendable {
        let item: SearchItem
        let name: String
        let other: String?
    }

    /// The kinds, in the order their matches are listed among equally good ones.
    private enum Kind: Int, CaseIterable {
        case artist, album, playlist, song
    }

    private(set) var artists: [ArtistID3] = []
    private(set) var albums: [AlbumID3] = []
    private(set) var playlists: [PlaylistSummary] = []
    private(set) var songs: [Child] = []
    private var entries: [[Entry]] = Array(repeating: [], count: Kind.allCases.count)

    /// What the last search matched, per kind (indices into `entries`), for narrowing the next one.
    private var narrowing: (query: String, candidates: [[Int]])?

    /// How many entries are looked at between checks for cancellation.
    private static let cancellationStride = 2048

    // MARK: - Index

    /// Each returns whether the list differs from the one held (and so the index was rebuilt): the
    /// loader reports the same cached list again whenever the screen is opened again.
    @discardableResult
    func update(artists new: [ArtistID3]) -> Bool {
        guard new != artists else { return false }
        artists = new
        setEntries(new.map { Entry(item: .artist($0), name: Self.fold($0.name), other: nil) }, for: .artist)
        return true
    }

    @discardableResult
    func update(albums new: [AlbumID3]) -> Bool {
        guard new != albums else { return false }
        albums = new
        setEntries(new.map { Entry(item: .album($0), name: Self.fold($0.name), other: $0.artist.map(Self.fold)) }, for: .album)
        return true
    }

    @discardableResult
    func update(playlists new: [PlaylistSummary]) -> Bool {
        guard new != playlists else { return false }
        playlists = new
        setEntries(new.map { Entry(item: .playlist($0), name: Self.fold($0.name), other: $0.owner.map(Self.fold)) }, for: .playlist)
        return true
    }

    @discardableResult
    func update(songs new: [Child]) -> Bool {
        guard new != songs else { return false }
        songs = new
        setEntries(new.map { Entry(item: .song($0), name: Self.fold($0.title), other: $0.artist.map(Self.fold)) }, for: .song)
        return true
    }

    private func setEntries(_ new: [Entry], for kind: Kind) {
        entries[kind.rawValue] = new
        narrowing = nil
    }

    /// `text` without case or diacritics: "Beyoncé" and "BEYONCE" are the same.
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Search

    /// The best `limit` matches of `rawQuery` and the thumbnails of their rows — `nil` if the
    /// calling task was cancelled (a newer query replaced this one). A name that starts with the
    /// query comes first, then one that contains it, then an item only its artist matches; within
    /// those, artists, albums, playlists and songs, each in the library's own order.
    func search(_ rawQuery: String, limit: Int, scale: CGFloat, artworkPoints: CGFloat) -> SearchOutcome? {
        let query = Self.fold(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return SearchOutcome(items: [], requests: []) }

        // Only valid for a query that contains the one the candidates are for.
        let previous = narrowing.flatMap { query.contains($0.query) ? $0.candidates : nil }

        // Filled kind by kind, so each bucket ends up in (kind, library) order without a sort.
        var buckets: [[SearchItem]] = [[], [], []]
        var matched: [[Int]] = Array(repeating: [], count: Kind.allCases.count)
        var examined = 0

        /// Scores the entries of `kind` at `indices` and files the ones that match. `false` if the
        /// task was cancelled meanwhile.
        func scan<Indices: Sequence<Int>>(_ kind: Kind, _ indices: Indices) -> Bool {
            let list = entries[kind.rawValue]
            for index in indices {
                examined += 1
                if examined % Self.cancellationStride == 0, Task.isCancelled { return false }
                let entry = list[index]
                let score: Int
                if entry.name.hasPrefix(query) {
                    score = 0
                } else if entry.name.contains(query) {
                    score = 1
                } else if let other = entry.other, other.contains(query) {
                    score = 2
                } else {
                    continue
                }
                matched[kind.rawValue].append(index)
                // Past the limit nothing more is listed, but the candidates still need all matches.
                if buckets[score].count < limit { buckets[score].append(entry.item) }
            }
            return true
        }

        for kind in Kind.allCases {
            let finished = if let previous { scan(kind, previous[kind.rawValue]) } else { scan(kind, entries[kind.rawValue].indices) }
            if !finished { return nil }
        }
        guard !Task.isCancelled else { return nil }
        narrowing = (query, matched)

        let items = Array(buckets.joined().prefix(limit))
        return SearchOutcome(items: items, requests: items.map { Self.request(for: $0, scale: scale, points: artworkPoints) })
    }

    /// The items for history `ids` (`SearchItem.id`s), in that order, with their thumbnails; one that
    /// is no longer in the library is left out.
    func items(matching ids: [String], scale: CGFloat, artworkPoints: CGFloat) -> SearchOutcome {
        // The ids by kind: "album-42" is the album "42" (the id itself may contain dashes).
        var wanted: [String: Set<String>] = [:]
        for id in ids {
            guard let dash = id.firstIndex(of: "-") else { continue }
            wanted[String(id[..<dash]), default: []].insert(String(id[id.index(after: dash)...]))
        }
        var found: [String: SearchItem] = [:]
        func keep(_ item: SearchItem) { found[item.id] = item }
        if let wanted = wanted["artist"] { artists.lazy.filter { wanted.contains($0.id.raw) }.forEach { keep(.artist($0)) } }
        if let wanted = wanted["album"] { albums.lazy.filter { wanted.contains($0.id.raw) }.forEach { keep(.album($0)) } }
        if let wanted = wanted["playlist"] { playlists.lazy.filter { wanted.contains($0.id.raw) }.forEach { keep(.playlist($0)) } }
        if let wanted = wanted["song"] { songs.lazy.filter { wanted.contains($0.id.raw) }.forEach { keep(.song($0)) } }

        let items = ids.compactMap { found[$0] }
        return SearchOutcome(items: items, requests: items.map { Self.request(for: $0, scale: scale, points: artworkPoints) })
    }

    /// The thumbnail a result's row shows.
    nonisolated static func request(for item: SearchItem, scale: CGFloat, points: CGFloat) -> ArtworkRequest {
        switch item {
        case .artist(let artist):
            .artistRow(artist.coverArt ?? artist.id.raw, scale: scale, points: points)
        case .album(let album):
            .albumRow(album.coverArt ?? album.id.raw, scale: scale, points: points)
        case .playlist(let playlist):
            .playlistRow(playlist.coverArt ?? playlist.id.raw, scale: scale, points: points)
        case .song(let song):
            .songRow(ArtworkRequest.artworkId(of: song), scale: scale, points: points)
        }
    }
}
