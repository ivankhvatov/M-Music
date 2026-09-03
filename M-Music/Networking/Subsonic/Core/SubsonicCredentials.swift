import Foundation

/// Everything needed to authenticate against a Subsonic/Navidrome server.
struct SubsonicCredentials: Equatable, Sendable {
    var baseURL: URL
    var username: String
    var password: String
}

/// Persists `SubsonicCredentials` across launches: the non-secret fields live in
/// `UserDefaults`, the password lives in the Keychain.
enum SubsonicCredentialsStore {
    private static let service = "com.mmusic.subsonic"
    private static let passwordAccount = "server-password"
    private static let baseURLKey = "subsonic.baseURL"
    private static let usernameKey = "subsonic.username"

    static func load() -> SubsonicCredentials? {
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: baseURLKey),
            let url = URL(string: urlString),
            let username = defaults.string(forKey: usernameKey),
            let password = Keychain.read(service: service, account: passwordAccount)
        else { return nil }
        return SubsonicCredentials(baseURL: url, username: username, password: password)
    }

    static func save(_ credentials: SubsonicCredentials) throws {
        let defaults = UserDefaults.standard
        defaults.set(credentials.baseURL.absoluteString, forKey: baseURLKey)
        defaults.set(credentials.username, forKey: usernameKey)
        try Keychain.save(service: service, account: passwordAccount, value: credentials.password)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: usernameKey)
        Keychain.delete(service: service, account: passwordAccount)
    }
}
