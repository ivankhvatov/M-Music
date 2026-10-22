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

    private func layout(
        order: String = "", disabled: String = "", genreCount: Int = 0,
        sections: HomeAlbumSections = HomeAlbumSections(),
        played: [AlbumID3] = [], playlists: [PlaylistSummary] = [],
        availability: HomeAvailability = .online
    ) -> HomeLayout {
        HomeLayoutBuilder.build(
            order: order, disabled: disabled, randomGenreCount: genreCount, sections: sections,
            recentlyPlayed: played, topPlaylists: playlists, availability: availability
        )
    }

    @Test func theFirstScreenFollowsTheCarouselOrderAndTakesThreeCardsOfEach() {
        var sections = HomeAlbumSections()
        sections.latestReleases = ["a", "b", "c", "d"].map(album)
        let built = layout(
            order: "recentlyPlayed,randomAlbums,latestReleases,topPlaylists", sections: sections,
            played: ["x", "y"].map(album), playlists: [playlist("p1")]
        )
        #expect(built.carousels.map(\.kind) == [.recentlyPlayed, .latestReleases, .topPlaylists])
        #expect(built.requests(perCarousel: 3, limit: 12) == [
            .albumCard("cover-x"), .albumCard("cover-y"),
            .albumCard("cover-a"), .albumCard("cover-b"), .albumCard("cover-c"),
            .playlistCard("pl-p1"),
        ])
    }

    @Test func theFirstScreenIsCappedAtTheGateLimit() {
        let many = (0..<20).map { album("m\($0)") }
        var sections = HomeAlbumSections()
        sections.random = many
        sections.latestReleases = many
        sections.recentlyAdded = many
        sections.favoriteArtists = many
        let built = layout(sections: sections, played: many)
        #expect(built.firstScreenRequests.count == ImageWarmer.gateLimit)
    }

    @Test func switchedOffAndEmptyCarouselsAreLeftOut() {
        var sections = HomeAlbumSections()
        sections.random = [album("z")]
        sections.latestReleases = [album("l")]
        let built = layout(disabled: "randomAlbums", sections: sections)
        #expect(built.carousels.map(\.kind) == [.latestReleases])
    }

    @Test func eachCardKnowsItsPositionItsCoverAndWhatItShows() {
        var sections = HomeAlbumSections()
        sections.random = ["a", "b"].map(album)
        let carousel = layout(sections: sections).carousels[0]
        #expect(carousel.source == "home.randomAlbums")
        #expect(carousel.cards.map(\.index) == [0, 1])
        #expect(carousel.cards.map(\.id) == ["a", "b"])
        #expect(carousel.cards[0].request == .albumCard("cover-a"))
        #expect(carousel.cards[0].title == "N")
        #expect(carousel.cards[0].subtitle == "Unknown Artist")
    }

    @Test func eachGenreGetsACarouselOfItsOwn() {
        var sections = HomeAlbumSections()
        sections.genres = [
            .init(name: "Jazz", albums: ["j1", "j2"].map(album)),
            .init(name: "Metal", albums: ["m1"].map(album)),
            .init(name: "Folk", albums: ["f1"].map(album)),
        ]
        let built = layout(genreCount: 2, sections: sections)
        #expect(built.carousels.map(\.source) == ["home.genre.jazz", "home.genre.metal"])
        #expect(built.carousels.map(\.title) == [.verbatim("Jazz"), .verbatim("Metal")])
        #expect(layout(genreCount: 0, sections: sections).carousels.isEmpty)
    }

    @Test func offlineOnlyDownloadedAlbumsAndPlaylistsAreAvailable() {
        var sections = HomeAlbumSections()
        sections.random = ["a", "b"].map(album)
        let offline = HomeAvailability(isOnline: false, albumIdsWithDownloads: ["b"], playlistIdsWithDownloads: ["p2"])
        let built = layout(sections: sections, playlists: ["p1", "p2"].map(playlist), availability: offline)
        let random = built.carousels.first { $0.kind == .randomAlbums }!
        #expect(random.cards.map(\.isAvailable) == [false, true])
        let playlists = built.carousels.first { $0.kind == .topPlaylists }!
        #expect(playlists.cards.map(\.isAvailable) == [false, true])
    }

    @Test func onlineEverythingIsAvailableWhateverTheDownloadSets() {
        var sections = HomeAlbumSections()
        sections.random = ["a"].map(album)
        let online = HomeAvailability(isOnline: true, albumIdsWithDownloads: [], playlistIdsWithDownloads: [])
        #expect(layout(sections: sections, availability: online).carousels[0].cards[0].isAvailable)
    }

    @Test func theSameInputsGiveAnEqualLayoutAndACardIgnoresWhatItDoesNotShow() {
        var sections = HomeAlbumSections()
        sections.random = ["a", "b"].map(album)
        #expect(layout(sections: sections) == layout(sections: sections))

        sections.random = ["a", "c"].map(album)
        #expect(layout(sections: sections) != layout(order: "", sections: HomeAlbumSections(random: ["a", "b"].map(album))))
    }

    @Test func onlyTheStableCarouselsAreRemembered() {
        var sections = HomeAlbumSections()
        sections.random = ["r"].map(album)
        sections.latestReleases = ["l"].map(album)
        sections.favoriteArtists = ["f"].map(album)
        let built = layout(sections: sections, played: [album("p")])
        #expect(built.rememberedRequests == [.albumCard("cover-l"), .albumCard("cover-p")])
    }

    @Test func theWarmCoordinatorWarmsAroundACardNearestFirst() {
        var sections = HomeAlbumSections()
        sections.random = (0..<10).map { album("c\($0)") }
        let carousel = layout(sections: sections).carousels[0]
        let requests = HomeWarmCoordinator.requests(around: 4, in: carousel)
        #expect(Array(requests.prefix(4)) == [.albumCard("cover-c5"), .albumCard("cover-c3"), .albumCard("cover-c6"), .albumCard("cover-c2")])
        #expect(requests.count == 9)
    }

    @Test func theWarmCoordinatorWarmsTheFirstCoversOfTheNeighbouringCarousels() {
        var sections = HomeAlbumSections()
        sections.random = (0..<20).map { album("r\($0)") }
        sections.latestReleases = (0..<20).map { album("l\($0)") }
        sections.recentlyAdded = (0..<20).map { album("a\($0)") }
        sections.favoriteArtists = (0..<20).map { album("f\($0)") }
        let built = layout(sections: sections)
        let requests = HomeWarmCoordinator.requestsOfNeighbors(of: 1, in: built)
        // After (recently added), before (random), then two after (favorites): 8 covers each.
        #expect(requests.count == 3 * ImageWarmer.neighborCarouselCards)
        #expect(requests.first == .albumCard("cover-a0"))
        #expect(requests.contains(.albumCard("cover-r0")))
        #expect(requests.contains(.albumCard("cover-f0")))
        #expect(!requests.contains(.albumCard("cover-l0")))
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

struct NeighborsTests {
    @Test func theNearestItemsOnBothSidesComeFirst() {
        let items = Array(0..<10)
        #expect(ImageWarmer.neighbors(of: 5, in: items, count: 4) == [6, 4, 7, 3])
    }

    @Test func atTheEndOnlyTheItemsBeforeAreLeft() {
        let items = Array(0..<6)
        #expect(ImageWarmer.neighbors(of: 5, in: items, count: 10) == [4, 3, 2, 1, 0])
    }

    @Test func atTheStartOnlyTheItemsAfterAreLeft() {
        let items = Array(0..<6)
        #expect(ImageWarmer.neighbors(of: 0, in: items, count: 3) == [1, 2, 3])
    }

    @Test func aWholeCarouselFitsInTheDefaultCount() {
        let items = Array(0..<20)
        #expect(Set(ImageWarmer.neighbors(of: 19, in: items, count: ImageWarmer.scrollAheadCount)) == Set(0..<19))
    }

    @Test func anOutOfRangeIndexOrAnEmptyListGivesNothing() {
        #expect(ImageWarmer.neighbors(of: 3, in: [Int](), count: 5).isEmpty)
        #expect(ImageWarmer.neighbors(of: 9, in: [1, 2], count: 5).isEmpty)
    }
}

#if DEBUG
struct PerfProbeTests {
    @Test func itSeesTheThreadsOfTheProcessAndTheMainThread() async {
        let loads = PerfProbe.sample()
        #expect(!loads.isEmpty)
        #expect(loads.contains { $0.isMain })
        #expect(loads.allSatisfy { $0.percent >= 0 })
    }
}
#endif

struct HomeRevealTests {
    @Test func startsWithTheFirstScreenAndGrowsInSteps() {
        #expect(HomeReveal.initialCount == 3)
        #expect(HomeReveal.next(3, total: 17) == 5)
        #expect(HomeReveal.next(5, total: 17) == 7)
    }

    @Test func neverGoesBeyondWhatExists() {
        #expect(HomeReveal.next(16, total: 17) == 17)
        #expect(HomeReveal.next(17, total: 17) == 17)
        #expect(HomeReveal.next(3, total: 2) == 2)
        #expect(HomeReveal.next(3, total: 0) == 0)
    }

    @Test func aShrinkingCarouselSetPullsTheCountBack() {
        #expect(HomeReveal.clamped(9, total: 6) == 6)
        #expect(HomeReveal.clamped(2, total: 6) == 2)
        #expect(HomeReveal.clamped(5, total: 0) == 0)
    }
}

struct ScrollActivityTests {
    @Test func backgroundWorkHoldsOffWhileScrollingAndForAMomentAfter() {
        let activity = ScrollActivity()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(!activity.isBusy(at: start))

        activity.set(scrolling: true, at: start)
        #expect(activity.isBusy(at: start.addingTimeInterval(5)))

        activity.set(scrolling: false, at: start.addingTimeInterval(5))
        #expect(activity.isBusy(at: start.addingTimeInterval(5.1)))
        #expect(!activity.isBusy(at: start.addingTimeInterval(5 + ScrollActivity.settleDelay + 0.01)))
    }

    @Test func waitingReturnsAsSoonAsNothingIsScrolling() async {
        let activity = ScrollActivity()
        activity.set(scrolling: true)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            activity.set(scrolling: false)
        }
        let started = ContinuousClock.now
        await activity.waitUntilIdle()
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(100))
        #expect(waited < .seconds(2))
    }
}
