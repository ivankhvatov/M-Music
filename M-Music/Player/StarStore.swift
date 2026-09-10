import Foundation

/// Single source of truth for which songs are starred — shared by `AlbumView`, `SongsListView`,
/// and `PlayerManager` (which mirrors the current track's state for the Now Playing screen and
/// the lock screen / Control Center "favorite" toggle). Each of those used to keep its own local
/// optimistic-update dictionary, which could drift out of sync with the others: starring a track
/// in one place wouldn't be reflected in another until its list was re-fetched from the server.
@MainActor
final class StarStore: ObservableObject {
    static let shared = StarStore()

    /// Overrides `Child.isStarred` (server-decoded, immutable per fetch) once a track's been
    /// toggled locally — keyed by song id. A track with no entry here falls back to its own
    /// `isStarred`.
    @Published private(set) var overrides: [String: Bool] = [:]

    private let client: SubsonicClient

    init(client: SubsonicClient = .shared) {
        self.client = client
    }

    func isStarred(_ track: Child) -> Bool {
        overrides[track.id.raw] ?? track.isStarred
    }

    func toggleStarred(_ track: Child) {
        let newValue = !isStarred(track)
        overrides[track.id.raw] = newValue
        Task {
            do {
                if newValue {
                    try await client.star(ids: [track.id.raw])
                } else {
                    try await client.unstar(ids: [track.id.raw])
                }
            } catch {
                await MainActor.run { self.overrides[track.id.raw] = !newValue }
            }
        }
    }
}
