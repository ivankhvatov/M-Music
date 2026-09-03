import Foundation

// MARK: - Playlists

struct PlaylistSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let name: String
    let comment: String?
    let owner: String?
    let `public`: Bool?
    let songCount: Int
    let duration: Int
    let created: String?
    let changed: String?
    let coverArt: String?
}

struct Playlists: Decodable, Sendable {
    let playlist: [PlaylistSummary]
}
extension Playlists: SubsonicPayload { static let responseKey = "playlists" }

struct PlaylistWithSongs: Decodable, Identifiable, Sendable {
    let id: FlexibleID
    let name: String
    let comment: String?
    let owner: String?
    let `public`: Bool?
    let songCount: Int
    let duration: Int
    let created: String?
    let changed: String?
    let coverArt: String?
    let entry: [Child]?
}
extension PlaylistWithSongs: SubsonicPayload { static let responseKey = "playlist" }

// MARK: - Lyrics

struct Lyrics: Decodable, Sendable {
    let artist: String?
    let title: String?
    let value: String?
}
extension Lyrics: SubsonicPayload { static let responseKey = "lyrics" }

// MARK: - Bookmarks & play queue

struct Bookmark: Decodable, Identifiable, Sendable {
    let position: Int
    let username: String
    let comment: String?
    let created: String
    let changed: String
    let entry: Child
    var id: String { "\(username)-\(entry.id)" }
}

struct Bookmarks: Decodable, Sendable {
    let bookmark: [Bookmark]?
}
extension Bookmarks: SubsonicPayload { static let responseKey = "bookmarks" }

struct PlayQueue: Decodable, Sendable {
    let current: FlexibleID?
    let position: Int64?
    let username: String
    let changed: String?
    let changedBy: String?
    let entry: [Child]?
}
extension PlayQueue: SubsonicPayload { static let responseKey = "playQueue" }

// MARK: - Sharing

struct Share: Decodable, Identifiable, Sendable {
    let id: FlexibleID
    let url: String
    let description: String?
    let username: String
    let created: String
    let expires: String?
    let lastVisited: String?
    let visitCount: Int
    let entry: [Child]?
}

struct Shares: Decodable, Sendable {
    let share: [Share]?
}
extension Shares: SubsonicPayload { static let responseKey = "shares" }

// MARK: - Internet radio

struct InternetRadioStation: Decodable, Identifiable, Hashable, Sendable {
    let id: FlexibleID
    let name: String
    let streamUrl: String
    let homepageUrl: String?
}

struct InternetRadioStations: Decodable, Sendable {
    let internetRadioStation: [InternetRadioStation]?
}
extension InternetRadioStations: SubsonicPayload { static let responseKey = "internetRadioStations" }

// MARK: - User management

struct SubsonicUser: Decodable, Identifiable, Sendable {
    let username: String
    let email: String?
    let scrobblingEnabled: Bool
    let adminRole: Bool
    let settingsRole: Bool
    let downloadRole: Bool
    let uploadRole: Bool
    let playlistRole: Bool
    let coverArtRole: Bool
    let commentRole: Bool
    let podcastRole: Bool
    let streamRole: Bool
    let jukeboxRole: Bool
    let shareRole: Bool
    let videoConversionRole: Bool?
    let maxBitRate: Int?
    var id: String { username }
}

struct Users: Decodable, Sendable {
    let user: [SubsonicUser]?
}
extension Users: SubsonicPayload { static let responseKey = "users" }
extension SubsonicUser: SubsonicPayload { static let responseKey = "user" }

// MARK: - Media library scanning

struct ScanStatus: Decodable, Sendable {
    let scanning: Bool
    let count: Int64?
    let folderCount: Int64?
    let lastScan: String?
    let error: String?
}
extension ScanStatus: SubsonicPayload { static let responseKey = "scanStatus" }
