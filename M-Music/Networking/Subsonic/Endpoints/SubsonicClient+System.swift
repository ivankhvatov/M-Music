import Foundation

// https://www.subsonic.org/pages/api.jsp#ping / #getLicense
extension SubsonicClient {
    /// Used mostly to test connectivity/credentials; throws `SubsonicError.server` on bad auth.
    func ping() async throws {
        try await sendVoid("ping")
    }

    func getLicense() async throws -> License {
        guard let license = try await send("getLicense", as: License.self) else {
            throw SubsonicError.invalidResponse
        }
        return license
    }
}
