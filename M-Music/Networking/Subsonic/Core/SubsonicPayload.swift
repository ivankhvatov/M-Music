import Foundation

/// A type that can be decoded from the single named element the Subsonic API nests
/// inside every `<subsonic-response>` (e.g. `"license"`, `"albumList2"`, `"artist"`).
protocol SubsonicPayload: Decodable {
    static var responseKey: String { get }
}

struct SubsonicAPIError: Decodable, Equatable, Sendable {
    let code: Int
    let message: String?
}

/// A payload type for endpoints that only ever return `status`/`error` and nothing else
/// (star, unstar, setRating, scrobble, deletePlaylist, ...).
struct EmptyPayload: SubsonicPayload {
    static let responseKey = "__none__"
}

/// Generic envelope for `{"subsonic-response": {"status": ..., "version": ..., "error": ..., "<key>": ...}}`.
///
/// The payload's element name varies per endpoint, so it's looked up dynamically via
/// `Payload.responseKey` instead of a fixed `CodingKey`.
struct SubsonicResponse<Payload: SubsonicPayload>: Decodable {
    let status: String
    let version: String
    let error: SubsonicAPIError?
    let payload: Payload?

    private enum RootKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }

    private struct BodyKey: CodingKey {
        let stringValue: String
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let body = try root.nestedContainer(keyedBy: BodyKey.self, forKey: .subsonicResponse)
        status = try body.decode(String.self, forKey: BodyKey("status"))
        version = try body.decode(String.self, forKey: BodyKey("version"))
        error = try body.decodeIfPresent(SubsonicAPIError.self, forKey: BodyKey("error"))
        payload = try body.decodeIfPresent(Payload.self, forKey: BodyKey(Payload.responseKey))
    }
}
