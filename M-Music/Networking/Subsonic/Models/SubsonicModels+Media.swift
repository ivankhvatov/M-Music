import Foundation

// MARK: - System

struct License: Decodable, Sendable {
    let valid: Bool
    let email: String?
    let licenseExpires: String?
    let trialExpires: String?
}
extension License: SubsonicPayload { static let responseKey = "license" }

/// ReplayGain tags (OpenSubsonic extension), reported per-song even for the album gain/peak
/// values — a song's `albumGain`/`albumPeak` are its *album's* values, repeated on every track
/// in it, since there's no separate album-level ReplayGain field in the API. All values are in
/// dB except the peaks, which are positive linear amplitudes.
struct ReplayGain: Codable, Hashable, Sendable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
    let baseGain: Double?
    /// A fallback gain the server suggests when the mode-appropriate gain above is missing —
    /// checked before `ReplayGainSettings.defaultGain` in `ReplayGainSettings.linearGain(for:)`.
    let fallbackGain: Double?
}

// MARK: - Child (a song, or a browse-by-folder directory entry)

/// Represents a single media file. Used for songs everywhere in the API, and also for
/// folder-style directory entries returned by `getMusicDirectory`/`getIndexes` (Navidrome
/// simulates a folder tree for those, per its docs).
struct Child: Codable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let parent: FlexibleID?
    let isDir: Bool
    let title: String
    /// The parent album's title. Navidrome bakes an ALBUMVERSION tag into this string server-side
    /// (see `AlbumVersionParsing`) with no separate field to split it back out from on its own —
    /// `albumVersion` below is only ever populated when this `Child` came from an
    /// `AlbumWithSongsID3` response, which does report the version separately and lets it be
    /// split precisely. A song fetched standalone (search, random, a playlist, ...) keeps
    /// whatever `album` string the server sent, version suffix and all.
    var album: String?
    let artist: String?
    let track: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let path: String?
    let isVideo: Bool?
    let userRating: Int?
    let averageRating: Double?
    let playCount: Int?
    let discNumber: Int?
    let created: String?
    let starred: String?
    let albumId: FlexibleID?
    let artistId: FlexibleID?
    let type: String?
    let bookmarkPosition: Int?
    /// The album's ALBUMVERSION tag (e.g. "Deluxe Edition"), split out of `album` — see its doc
    /// comment. Not a real server field: only ever set by `AlbumWithSongsID3`'s decoding, never
    /// present in the raw JSON for a standalone song. `var` (not `let`) so `withAlbumTitle`
    /// below can produce a corrected copy.
    var albumVersion: String?
    /// ReplayGain tags (OpenSubsonic extension) — track and album gain/peak, plus optional
    /// base/fallback values. `nil` if the file has no ReplayGain metadata at all.
    let replayGain: ReplayGain?

    var isStarred: Bool { starred != nil }

    /// Audio codec/format, e.g. "FLAC", "MP3". Subsonic has no dedicated codec tag — `suffix`
    /// (the file extension) is the closest thing to it, so that's what this derives from.
    var codec: String? { suffix?.uppercased() }

    enum CodingKeys: String, CodingKey {
        case id, parent, isDir, title, album, artist, track, year, genre, coverArt, size
        case contentType, suffix, duration, bitRate, path, isVideo, userRating, averageRating
        case playCount, discNumber, created, starred, albumId, artistId, type, bookmarkPosition
        case albumVersion, replayGain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleID.self, forKey: .id)
        parent = try c.decodeIfPresent(FlexibleID.self, forKey: .parent)
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        title = try c.decode(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating)
        averageRating = try c.decodeIfPresent(Double.self, forKey: .averageRating)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        starred = try c.decodeIfPresent(String.self, forKey: .starred)
        albumId = try c.decodeIfPresent(FlexibleID.self, forKey: .albumId)
        artistId = try c.decodeIfPresent(FlexibleID.self, forKey: .artistId)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        bookmarkPosition = try c.decodeIfPresent(Int.self, forKey: .bookmarkPosition)
        albumVersion = try c.decodeIfPresent(String.self, forKey: .albumVersion)
        replayGain = try c.decodeIfPresent(ReplayGain.self, forKey: .replayGain)
    }

    /// Builds a `Child` directly rather than by decoding server JSON — used to turn a locally
    /// downloaded song (`DownloadRecord`) back into the same type the player queue and song rows
    /// already work with. Fields the download pipeline doesn't track (folder-browsing metadata,
    /// ratings, play history, ...) default to their "unknown" value.
    init(
        id: FlexibleID, title: String, album: String?, artist: String?, track: Int?, year: Int?,
        genre: String?, coverArt: String?, size: Int64?, contentType: String?, suffix: String?,
        duration: Int?, bitRate: Int?, discNumber: Int?, starred: String?, albumId: FlexibleID?,
        artistId: FlexibleID?, replayGain: ReplayGain?
    ) {
        self.id = id
        self.parent = nil
        self.isDir = false
        self.title = title
        self.album = album
        self.artist = artist
        self.track = track
        self.year = year
        self.genre = genre
        self.coverArt = coverArt
        self.size = size
        self.contentType = contentType
        self.suffix = suffix
        self.duration = duration
        self.bitRate = bitRate
        self.path = nil
        self.isVideo = nil
        self.userRating = nil
        self.averageRating = nil
        self.playCount = nil
        self.discNumber = discNumber
        self.created = nil
        self.starred = starred
        self.albumId = albumId
        self.artistId = artistId
        self.type = nil
        self.bookmarkPosition = nil
        self.albumVersion = nil
        self.replayGain = replayGain
    }

    /// Returns a copy with `album`/`albumVersion` overridden. Used by `AlbumWithSongsID3`'s
    /// decoding, which knows the exact ALBUMVERSION value for every song in it (from the sibling
    /// `version` field) and can split each song's `album` precisely — see `AlbumVersionParsing`.
    func withAlbumTitle(_ album: String?, version: String?) -> Child {
        var copy = self
        copy.album = album
        copy.albumVersion = version
        return copy
    }
}
extension Child: SubsonicPayload { static let responseKey = "song" }

// MARK: - Browsing by folder (getMusicFolders, getIndexes, getMusicDirectory)

struct MusicFolder: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let name: String?
}

struct MusicFolders: Decodable, Sendable {
    let musicFolder: [MusicFolder]
}
extension MusicFolders: SubsonicPayload { static let responseKey = "musicFolders" }

/// The old-style (non-ID3) artist reference used by `getIndexes`/`search2`/`getStarred`.
struct ArtistRef: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let name: String
    let starred: String?
    var isStarred: Bool { starred != nil }
}

struct IndexEntry: Decodable, Hashable, Sendable {
    let name: String
    let artist: [ArtistRef]
}

struct Indexes: Decodable, Sendable {
    let lastModified: Int64?
    let ignoredArticles: String?
    let shortcut: [ArtistRef]?
    let index: [IndexEntry]?
    let child: [Child]?
}
extension Indexes: SubsonicPayload { static let responseKey = "indexes" }

struct Directory: Decodable, Identifiable, Sendable {
    let id: FlexibleID
    let parent: FlexibleID?
    let name: String
    let starred: String?
    let child: [Child]?
}
extension Directory: SubsonicPayload { static let responseKey = "directory" }

// MARK: - Genres

struct Genre: Decodable, Identifiable, Hashable, Sendable {
    let value: String
    let songCount: Int
    let albumCount: Int
    var id: String { value }
}

struct Genres: Decodable, Sendable {
    let genre: [Genre]
}
extension Genres: SubsonicPayload { static let responseKey = "genres" }

// MARK: - Artists / Albums (ID3, tag-based browsing — the recommended, non-folder API)

struct ArtistID3: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let name: String
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let userRating: Int?
    var isStarred: Bool { starred != nil }
}

/// `Encodable` only for `LibraryCacheDatabase`, which re-serializes it to persist for offline
/// browsing — `SubsonicClient` itself never re-encodes anything it decodes. Must live in this
/// file: Swift can only synthesize `encode(to:)` in the same file as the type declaration.
extension ArtistID3: Encodable {}

struct IndexID3: Decodable, Hashable, Sendable {
    let name: String
    let artist: [ArtistID3]
}

struct ArtistsID3: Decodable, Sendable {
    let ignoredArticles: String?
    let index: [IndexID3]
}
extension ArtistsID3: SubsonicPayload { static let responseKey = "artists" }

/// A record/publishing label credited on an album — the OpenSubsonic `recordLabels` field,
/// sourced from the album's LABEL/RECORDLABEL tag. Navidrome only exposes this (and
/// `releaseTypes` below) on albums, never on individual songs, even though the tag itself
/// lives on the track files — there's no per-song equivalent in the API.
struct RecordLabel: Codable, Hashable, Sendable {
    let name: String
}

/// Mirrors Navidrome's `appendSuffix` helper — used server-side to bake an ALBUMVERSION tag
/// into an album's display name (`name`/`FullName()`) and each of its songs' album name
/// (`FullAlbumName()`) when the admin has `AppendAlbumVersion` enabled — so a title it applied
/// that transform to can be split back into a clean title and the version.
///
/// This only works given the *exact* version value to look for, which Navidrome does report
/// separately (`AlbumID3`'s `version` field, an OpenSubsonic extension) — so there's no
/// guessing involved, just checking whether the one suffix that value would produce is
/// actually there. There's no equivalent for a standalone song with no known album version to
/// check against (see `Child.album`'s doc comment); this is deliberately not a general
/// "strip anything that looks bracketed" heuristic, since plenty of legitimate titles
/// legitimately end in "(Live)", "(1975)", and the like without ever having gone through
/// `appendSuffix` at all.
enum AlbumVersionParsing {
    /// From Navidrome's `model/mediafile.go`: `var bracketPairs = map[byte]byte{'(': ')', '[': ']', '{': '}', '<': '>'}`.
    private static let bracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]

    /// Removes the exact suffix `appendSuffix(_, version)` would have produced, if `fullTitle`
    /// actually ends with it. Returns `fullTitle` unchanged otherwise (including when `version`
    /// is `nil`/empty).
    static func strippingSuffix(forVersion version: String?, from fullTitle: String) -> String {
        guard let version, !version.isEmpty else { return fullTitle }
        let suffix = appendedSuffix(for: version)
        guard fullTitle.count > suffix.count, fullTitle.hasSuffix(suffix) else { return fullTitle }
        return String(fullTitle.dropLast(suffix.count))
    }

    /// Reimplementation of Navidrome's `appendSuffix(_, version)`, minus the base title (i.e.
    /// just the part it adds after it).
    private static func appendedSuffix(for version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last, bracketPairs[first] == last {
            return " " + trimmed
        }
        return " (" + trimmed + ")"
    }
}

struct AlbumID3: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    /// Clean album title — any ALBUMVERSION suffix Navidrome may have appended (server config
    /// `AppendAlbumVersion`) is split out into `version` below instead.
    let name: String
    let artist: String?
    let artistId: FlexibleID?
    let coverArt: String?
    let songCount: Int
    let duration: Int
    let playCount: Int?
    let created: String?
    let starred: String?
    let year: Int?
    let genre: String?
    let userRating: Int?
    /// From the LABEL/RECORDLABEL tag (OpenSubsonic extension).
    var recordLabels: [RecordLabel]? = nil
    /// From the RELEASETYPE tag — e.g. "album", "compilation", "ep", "live" (OpenSubsonic extension).
    var releaseTypes: [String]? = nil
    /// From the ALBUMVERSION tag (OpenSubsonic `version` field) — e.g. "Deluxe Edition",
    /// "Remastered". `nil` if the album has no ALBUMVERSION tag.
    let version: String?
    var isStarred: Bool { starred != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, playCount, created
        case starred, year, genre, userRating, recordLabels, releaseTypes, version
    }

    /// A custom `Decodable.init(from:)` (below) suppresses Swift's automatic memberwise init,
    /// so this restates it explicitly — used for previews/tests, never for real server data.
    init(
        id: FlexibleID, name: String, artist: String?, artistId: FlexibleID?, coverArt: String?,
        songCount: Int, duration: Int, playCount: Int?, created: String?, starred: String?,
        year: Int?, genre: String?, userRating: Int?,
        recordLabels: [RecordLabel]? = nil, releaseTypes: [String]? = nil, version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.playCount = playCount
        self.created = created
        self.starred = starred
        self.year = year
        self.genre = genre
        self.userRating = userRating
        self.recordLabels = recordLabels
        self.releaseTypes = releaseTypes
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleID.self, forKey: .id)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(FlexibleID.self, forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decode(Int.self, forKey: .songCount)
        duration = try c.decode(Int.self, forKey: .duration)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        starred = try c.decodeIfPresent(String.self, forKey: .starred)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating)
        recordLabels = try c.decodeIfPresent([RecordLabel].self, forKey: .recordLabels)
        releaseTypes = try c.decodeIfPresent([String].self, forKey: .releaseTypes)

        let rawName = try c.decode(String.self, forKey: .name)
        let rawVersion = try c.decodeIfPresent(String.self, forKey: .version)?.trimmingCharacters(in: .whitespaces)
        version = (rawVersion?.isEmpty ?? true) ? nil : rawVersion
        name = AlbumVersionParsing.strippingSuffix(forVersion: version, from: rawName)
    }
}

/// `Encodable` only for `LibraryCacheDatabase` — see `ArtistID3.Encodable`'s doc comment above
/// for why, and why this has to live in this same file. Synthesis reuses the `CodingKeys` already
/// declared above for the custom decoder.
extension AlbumID3: Encodable {}

struct ArtistWithAlbumsID3: Decodable, Sendable {
    let id: FlexibleID
    let name: String
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let userRating: Int?
    let album: [AlbumID3]
}
extension ArtistWithAlbumsID3: SubsonicPayload { static let responseKey = "artist" }

struct AlbumWithSongsID3: Codable, Sendable {
    let id: FlexibleID
    /// Clean album title — see `AlbumID3.name`'s doc comment; same deal here.
    let name: String
    let artist: String?
    let artistId: FlexibleID?
    let coverArt: String?
    let songCount: Int
    let duration: Int
    let playCount: Int?
    let created: String?
    let starred: String?
    let year: Int?
    let genre: String?
    let userRating: Int?
    /// From the LABEL/RECORDLABEL tag (OpenSubsonic extension).
    var recordLabels: [RecordLabel]? = nil
    /// From the RELEASETYPE tag — e.g. "album", "compilation", "ep", "live" (OpenSubsonic extension).
    var releaseTypes: [String]? = nil
    /// From the ALBUMVERSION tag (OpenSubsonic `version` field). `nil` if the album has none.
    let version: String?
    /// Each song's `album`/`albumVersion` are corrected to match `name`/`version` above — see
    /// `Child.withAlbumTitle`. Since this type knows the exact version value, that correction is
    /// precise, unlike the general case for a standalone `Child`.
    let song: [Child]?

    /// The album's audio codec, taken from its first track. Subsonic has no album-level codec
    /// field — this is derived from the track list, so it's `nil` until `song` is populated.
    var codec: String? { song?.first?.codec }

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, playCount, created
        case starred, year, genre, userRating, recordLabels, releaseTypes, version, song
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleID.self, forKey: .id)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(FlexibleID.self, forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decode(Int.self, forKey: .songCount)
        duration = try c.decode(Int.self, forKey: .duration)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        starred = try c.decodeIfPresent(String.self, forKey: .starred)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating)
        recordLabels = try c.decodeIfPresent([RecordLabel].self, forKey: .recordLabels)
        releaseTypes = try c.decodeIfPresent([String].self, forKey: .releaseTypes)

        let rawName = try c.decode(String.self, forKey: .name)
        let rawVersion = try c.decodeIfPresent(String.self, forKey: .version)?.trimmingCharacters(in: .whitespaces)
        let version = (rawVersion?.isEmpty ?? true) ? nil : rawVersion
        self.version = version
        name = AlbumVersionParsing.strippingSuffix(forVersion: version, from: rawName)

        let rawSongs = try c.decodeIfPresent([Child].self, forKey: .song)
        guard let version, let rawSongs else {
            song = rawSongs
            return
        }
        song = rawSongs.map { track in
            guard let album = track.album else { return track }
            let cleaned = AlbumVersionParsing.strippingSuffix(forVersion: version, from: album)
            guard cleaned != album else { return track }
            return track.withAlbumTitle(cleaned, version: version)
        }
    }
}
extension AlbumWithSongsID3: SubsonicPayload { static let responseKey = "album" }

// MARK: - Album/song lists

struct AlbumList: Decodable, Sendable {
    let album: [Child]?
}
extension AlbumList: SubsonicPayload { static let responseKey = "albumList" }

struct AlbumList2: Decodable, Sendable {
    let album: [AlbumID3]?
}
extension AlbumList2: SubsonicPayload { static let responseKey = "albumList2" }

struct RandomSongs: Decodable, Sendable {
    let song: [Child]?
}
extension RandomSongs: SubsonicPayload { static let responseKey = "randomSongs" }

struct SongsByGenre: Decodable, Sendable {
    let song: [Child]?
}
extension SongsByGenre: SubsonicPayload { static let responseKey = "songsByGenre" }

struct NowPlayingEntry: Decodable, Identifiable, Sendable {
    let username: String
    let minutesAgo: Int
    let playerId: Int?
    let playerName: String?
    let song: Child

    var id: String { "\(username)-\(song.id)" }

    enum CodingKeys: String, CodingKey {
        case username, minutesAgo, playerId, playerName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        minutesAgo = try c.decode(Int.self, forKey: .minutesAgo)
        playerId = try c.decodeIfPresent(Int.self, forKey: .playerId)
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName)
        // The song's own fields (id, title, artist, ...) are flattened into the same object.
        song = try Child(from: decoder)
    }
}

struct NowPlaying: Decodable, Sendable {
    let entry: [NowPlayingEntry]?
}
extension NowPlaying: SubsonicPayload { static let responseKey = "nowPlaying" }

struct Starred: Decodable, Sendable {
    let artist: [ArtistRef]?
    let album: [Child]?
    let song: [Child]?
}
extension Starred: SubsonicPayload { static let responseKey = "starred" }

struct Starred2: Decodable, Sendable {
    let artist: [ArtistID3]?
    let album: [AlbumID3]?
    let song: [Child]?
}
extension Starred2: SubsonicPayload { static let responseKey = "starred2" }

// MARK: - Searching

struct SearchResult2: Decodable, Sendable {
    let artist: [ArtistRef]?
    let album: [Child]?
    let song: [Child]?
}
extension SearchResult2: SubsonicPayload { static let responseKey = "searchResult2" }

struct SearchResult3: Decodable, Sendable {
    let artist: [ArtistID3]?
    let album: [AlbumID3]?
    let song: [Child]?
}
extension SearchResult3: SubsonicPayload { static let responseKey = "searchResult3" }

// MARK: - Artist/album info & recommendations

struct ArtistInfo: Decodable, Sendable {
    let biography: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
    let similarArtist: [ArtistRef]?
}
extension ArtistInfo: SubsonicPayload { static let responseKey = "artistInfo" }

struct ArtistInfo2: Decodable, Sendable {
    let biography: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
    let similarArtist: [ArtistID3]?
}
extension ArtistInfo2: SubsonicPayload { static let responseKey = "artistInfo2" }

struct AlbumInfo: Decodable, Sendable {
    let notes: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}
extension AlbumInfo: SubsonicPayload { static let responseKey = "albumInfo" }

/// Same shape as `AlbumInfo`, but `getAlbumInfo2` nests it under a different key (`albumInfo2`).
struct AlbumInfo2: Decodable, Sendable {
    let notes: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}
extension AlbumInfo2: SubsonicPayload { static let responseKey = "albumInfo2" }

struct TopSongs: Decodable, Sendable {
    let song: [Child]?
}
extension TopSongs: SubsonicPayload { static let responseKey = "topSongs" }

struct SimilarSongs: Decodable, Sendable {
    let song: [Child]?
}
extension SimilarSongs: SubsonicPayload { static let responseKey = "similarSongs" }

struct SimilarSongs2: Decodable, Sendable {
    let song: [Child]?
}
extension SimilarSongs2: SubsonicPayload { static let responseKey = "similarSongs2" }
