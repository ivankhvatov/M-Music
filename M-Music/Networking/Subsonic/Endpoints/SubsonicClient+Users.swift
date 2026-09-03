import Foundation

// https://www.subsonic.org/pages/api.jsp#getUser / #getUsers
// Navidrome only supports reading users, not creating/updating/deleting them via the API
// (that's managed through its own admin UI), and `getUser` ignores the `username` parameter,
// always returning the authenticated user.
extension SubsonicClient {

    func getUser(username: String) async throws -> SubsonicUser {
        guard let user = try await send("getUser", [URLQueryItem(name: "username", value: username)], as: SubsonicUser.self) else {
            throw SubsonicError.invalidResponse
        }
        return user
    }

    /// The currently authenticated user's account details.
    func getCurrentUser() async throws -> SubsonicUser {
        guard let credentials else { throw SubsonicError.notConfigured }
        return try await getUser(username: credentials.username)
    }

    /// Admin only.
    func getUsers() async throws -> [SubsonicUser] {
        try await send("getUsers", as: Users.self)?.user ?? []
    }
}
