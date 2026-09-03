import Foundation

// https://www.subsonic.org/pages/api.jsp#getInternetRadioStations ... #deleteInternetRadioStation
extension SubsonicClient {

    func getInternetRadioStations() async throws -> [InternetRadioStation] {
        try await send("getInternetRadioStations", as: InternetRadioStations.self)?.internetRadioStation ?? []
    }

    func createInternetRadioStation(streamUrl: String, name: String, homepageUrl: String? = nil) async throws {
        var params = [URLQueryItem(name: "streamUrl", value: streamUrl), URLQueryItem(name: "name", value: name)]
        if let homepageUrl { params.append(URLQueryItem(name: "homepageUrl", value: homepageUrl)) }
        try await sendVoid("createInternetRadioStation", params, method: "POST")
    }

    func updateInternetRadioStation(id: String, streamUrl: String, name: String, homepageUrl: String? = nil) async throws {
        var params = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "streamUrl", value: streamUrl),
            URLQueryItem(name: "name", value: name),
        ]
        if let homepageUrl { params.append(URLQueryItem(name: "homepageUrl", value: homepageUrl)) }
        try await sendVoid("updateInternetRadioStation", params, method: "POST")
    }

    func deleteInternetRadioStation(id: String) async throws {
        try await sendVoid("deleteInternetRadioStation", [URLQueryItem(name: "id", value: id)], method: "POST")
    }
}
