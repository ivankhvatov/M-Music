import Foundation

// https://www.subsonic.org/pages/api.jsp#getShares ... #deleteShare
extension SubsonicClient {

    func getShares() async throws -> [Share] {
        try await send("getShares", as: Shares.self)?.share ?? []
    }

    /// Creates a public share link for one or more songs/albums. `expires` is optional;
    /// omit it for a link that never expires.
    @discardableResult
    func createShare(ids: [String], description: String? = nil, expires: Date? = nil) async throws -> [Share] {
        var params = ids.map { URLQueryItem(name: "id", value: $0) }
        if let description { params.append(URLQueryItem(name: "description", value: description)) }
        if let expires { params.append(URLQueryItem(name: "expires", value: String(Int64(expires.timeIntervalSince1970 * 1000)))) }
        return try await send("createShare", params, method: "POST", as: Shares.self)?.share ?? []
    }

    /// Pass `expires: nil` to leave the expiry unchanged, or a past/zero date isn't supported by
    /// the spec for clearing — create a new share instead if you need to remove an expiry.
    func updateShare(id: String, description: String? = nil, expires: Date? = nil) async throws {
        var params = [URLQueryItem(name: "id", value: id)]
        if let description { params.append(URLQueryItem(name: "description", value: description)) }
        if let expires { params.append(URLQueryItem(name: "expires", value: String(Int64(expires.timeIntervalSince1970 * 1000)))) }
        try await sendVoid("updateShare", params, method: "POST")
    }

    func deleteShare(id: String) async throws {
        try await sendVoid("deleteShare", [URLQueryItem(name: "id", value: id)], method: "POST")
    }
}
