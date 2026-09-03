import Foundation

// https://www.subsonic.org/pages/api.jsp#getScanStatus / #startScan
extension SubsonicClient {

    func getScanStatus() async throws -> ScanStatus {
        guard let status = try await send("getScanStatus", as: ScanStatus.self) else {
            throw SubsonicError.invalidResponse
        }
        return status
    }

    /// Triggers a library scan; returns the (usually `scanning: true`) status right after kicking it off.
    @discardableResult
    func startScan() async throws -> ScanStatus {
        guard let status = try await send("startScan", method: "POST", as: ScanStatus.self) else {
            throw SubsonicError.invalidResponse
        }
        return status
    }
}
