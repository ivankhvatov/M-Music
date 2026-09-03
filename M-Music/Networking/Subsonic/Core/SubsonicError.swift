import Foundation

enum SubsonicError: Error, LocalizedError, Equatable {
    /// No server/credentials have been configured yet — call `SubsonicClient.connect(baseURL:username:password:)` first.
    case notConfigured
    case invalidBaseURL
    case invalidResponse
    case http(status: Int)
    case decoding(String)
    /// The server understood the request but rejected it; `code` is the Subsonic API error code.
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No Navidrome server is configured yet."
        case .invalidBaseURL:
            return "The server address is not a valid URL."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .http(let status):
            return "The server responded with HTTP status \(status)."
        case .decoding(let detail):
            return "Couldn't understand the server's response: \(detail)"
        case .server(let code, let message):
            return SubsonicError.message(forCode: code, fallback: message)
        }
    }

    /// Human-readable text for the standard Subsonic API error codes.
    /// See https://www.subsonic.org/pages/api.jsp
    static func message(forCode code: Int, fallback: String) -> String {
        switch code {
        case 0: return "A generic error occurred: \(fallback)"
        case 10: return "A required parameter was missing from the request."
        case 20: return "M-Music is using an API version the server no longer supports. Please update the app."
        case 30: return "The server is running an older version of the Subsonic API than required."
        case 40: return "Wrong username or password."
        case 41: return "Token authentication isn't supported for LDAP users."
        case 50: return "You're not authorized to perform this action."
        case 60: return "The server's trial period has expired. Please upgrade your Navidrome license."
        case 70: return "The requested item was not found on the server."
        default: return fallback
        }
    }
}
