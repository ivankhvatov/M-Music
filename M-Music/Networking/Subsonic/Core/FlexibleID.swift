import Foundation

/// Subsonic/OpenSubsonic IDs are opaque strings on Navidrome (MD5 hashes or UUIDs) but
/// plain integers on some older/other servers. `FlexibleID` accepts either wire format
/// and normalizes it to a `String` so model code never has to care which server sent it.
struct FlexibleID: Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    init(stringLiteral value: String) {
        self.raw = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            raw = string
        } else if let intValue = try? container.decode(Int.self) {
            raw = String(intValue)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a String or Int id")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var description: String { raw }
}
