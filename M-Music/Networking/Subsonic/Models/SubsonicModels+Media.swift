import Foundation

// MARK: - System

struct License: Decodable, Sendable {
    let valid: Bool
    let email: String?
    let licenseExpires: String?
    let trialExpires: String?
}
extension License: SubsonicPayload { static let responseKey = "license" }

// MARK: - Child (a song, or a browse-by-folder directory entry)

/// Represents a single media file. Used for songs everywhere in the API, and also for
/// folder-style directory entries returned by `getMusicDirectory`/`getIndexes` (Navidrome
/// simulates a folder tree for those, per its docs).
struct Child: Codable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let parent: FlexibleID?
    let isDir: Bool
    let title: String
    let album: String?
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

    var isStarred: Bool { starred != nil }

    /// Audio codec/format, e.g. "FLAC", "MP3". Subsonic has no dedicated codec tag — `suffix`
    /// (the file extension) is the closest thing to it, so that's what this derives from.
    var codec: String? { suffix?.uppercased() }

    enum CodingKeys: String, CodingKey {
        case id, parent, isDir, title, album, artist, track, year, genre, coverArt, size
        case contentType, suffix, duration, bitRate, path, isVideo, userRating, averageRating
        case playCount, discNumber, created, starred, albumId, artistId, type, bookmarkPosition
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

struct AlbumID3: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
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
    var isStarred: Bool { starred != nil }
}

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
    let song: [Child]?

    /// The album's audio codec, taken from its first track. Subsonic has no album-level codec
    /// field — this is derived from the track list, so it's `nil` until `song` is populated.
    var codec: String? { song?.first?.codec }
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
