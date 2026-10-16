import Foundation
import Testing
@testable import M_Music

struct HomeLoadingPolicyTests {
    private func album(_ id: String) -> AlbumID3 {
        let json = #"{"id":"\#(id)","name":"N","songCount":1,"duration":1,"created":"2024-01-01T00:00:00Z","coverArt":"cover-\#(id)"}"#
        return try! JSONDecoder().decode(AlbumID3.self, from: Data(json.utf8))
    }

    private func playlist(_ id: String) -> PlaylistSummary {
        let json = #"{"id":"\#(id)","name":"P","songCount":1,"duration":1,"coverArt":"pl-\#(id)"}"#
        return try! JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
    }

    @Test func theFirstScreenFollowsTheCarouselOrderAndTakesThreeCardsOfEach() {
        let albums: (HomeCarouselKind) -> [AlbumID3] = { kind in
            switch kind {
            case .latestReleases: ["a", "b", "c", "d"].map(self.album)
            case .recentlyPlayed: ["x", "y"].map(self.album)
            default: []
            }
        }
        let requests = HomeLoadingPolicy.firstScreenRequests(
            carousels: [.recentlyPlayed, .randomAlbums, .latestReleases, .topPlaylists],
            albums: albums, playlists: [playlist("p1")]
        )
        #expect(requests == [
            .albumCard("cover-x"), .albumCard("cover-y"),
            .albumCard("cover-a"), .albumCard("cover-b"), .albumCard("cover-c"),
            .playlistCard("pl-p1"),
        ])
    }

    @Test func theFirstScreenIsCappedAtTheGateLimit() {
        let many = (0..<20).map { album("m\($0)") }
        let requests = HomeLoadingPolicy.firstScreenRequests(
            carousels: [.randomAlbums, .latestReleases, .recentlyAdded, .recentlyPlayed, .favoriteArtistAlbums],
            albums: { _ in many }, playlists: []
        )
        #expect(requests.count == ImageWarmer.gateLimit)
    }

    @Test func switchedOffCarouselsContributeNothing() {
        let requests = HomeLoadingPolicy.firstScreenRequests(
            carousels: [.topPlaylists], albums: { _ in [self.album("z")] }, playlists: []
        )
        #expect(requests.isEmpty)
    }

    @Test func theExpensiveRefreshRunsFirstThenOnlyAfterTheInterval() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(HomeLoadingPolicy.shouldRunExpensiveRefresh(last: nil, now: start))
        #expect(!HomeLoadingPolicy.shouldRunExpensiveRefresh(last: start, now: start.addingTimeInterval(299)))
        #expect(HomeLoadingPolicy.shouldRunExpensiveRefresh(last: start, now: start.addingTimeInterval(300)))
    }

    @Test func theTopPlaylistsAreTheMostPlayedOnesWithAnyPlays() {
        let playlists = ["a", "b", "c", "d"].map(playlist)
        let ranked = HomeLoadingPolicy.rank(playlists, playCounts: ["a": 1, "b": 9, "c": 0, "d": 5], limit: 2)
        #expect(ranked.map(\.id.raw) == ["b", "d"])
    }

    @Test func theFirstFrameWaitsOnlyForTheDataOfCarouselsThatAreOn() {
        #expect(HomeLoadingPolicy.parts(for: [.recentlyPlayed]) == [.recentlyPlayed])
        #expect(HomeLoadingPolicy.parts(for: [.randomAlbums, .favoriteArtistAlbums, .topPlaylists]) == [.library, .topPlaylists])
        #expect(HomeLoadingPolicy.parts(for: []).isEmpty)
    }
}

struct BoundedConcurrencyTests {
    private actor Peak {
        private var running = 0
        private(set) var peak = 0
        func enter() { running += 1; peak = max(peak, running) }
        func leave() { running -= 1 }
    }

    @Test func resultsKeepTheItemOrder() async {
        let results = await BoundedConcurrency.map(Array(0..<20), limit: 4) { value -> Int in
            try? await Task.sleep(for: .milliseconds(20 - value))
            return value * 2
        }
        #expect(results == (0..<20).map { $0 * 2 })
    }

    @Test func neverRunsMoreThanTheLimitAtOnce() async {
        let peak = Peak()
        _ = await BoundedConcurrency.map(Array(0..<30), limit: 3) { _ -> Int in
            await peak.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await peak.leave()
            return 0
        }
        #expect(await peak.peak <= 3)
    }

    @Test func noItemsIsNoWork() async {
        let results = await BoundedConcurrency.map([Int](), limit: 3) { $0 }
        #expect(results.isEmpty)
    }
}
