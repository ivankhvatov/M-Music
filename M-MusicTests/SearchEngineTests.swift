import Foundation
import Testing
@testable import M_Music

private func artist(_ id: String, _ name: String) -> ArtistID3 {
    ArtistID3(id: FlexibleID(id), name: name, coverArt: nil, albumCount: nil, starred: nil, userRating: nil)
}

private func album(_ id: String, _ name: String, by artist: String? = nil) -> AlbumID3 {
    AlbumID3(
        id: FlexibleID(id), name: name, artist: artist, artistId: nil, coverArt: nil, songCount: 1, duration: 1,
        playCount: nil, created: nil, starred: nil, year: nil, genre: nil, userRating: nil, version: nil
    )
}

private func playlist(_ id: String, _ name: String, owner: String? = nil) -> PlaylistSummary {
    PlaylistSummary(
        id: FlexibleID(id), name: name, comment: nil, owner: owner, public: nil, songCount: 0, duration: 0,
        created: nil, changed: nil, coverArt: nil
    )
}

private func song(_ id: String, _ title: String, by artist: String? = nil) -> Child {
    Child(
        id: FlexibleID(id), title: title, album: nil, artist: artist, track: nil, year: nil, genre: nil,
        coverArt: nil, size: nil, contentType: nil, suffix: nil, duration: nil, bitRate: nil, discNumber: nil,
        starred: nil, albumId: nil, artistId: nil, replayGain: nil
    )
}

private func ids(_ outcome: SearchOutcome?) -> [String] {
    (outcome?.items ?? []).map(\.id)
}

private func search(_ engine: SearchEngine, _ query: String, limit: Int = 300) async -> SearchOutcome? {
    await engine.search(query, limit: limit, scale: 3, artworkPoints: 56)
}

struct SearchEngineTests {
    @Test func ranksPrefixThenContainsThenOtherField() async {
        let engine = SearchEngine()
        await engine.update(songs: [
            song("s1", "Night Drive", by: "Moon"),  // only its artist matches
            song("s2", "Blue Moon"),                // contains
            song("s3", "Moonlight"),                // prefix
        ])
        let found = ids(await search(engine, "moon"))
        #expect(found == ["song-s3", "song-s2", "song-s1"])
    }

    @Test func listsKindsInOrderAmongEquallyGoodMatches() async {
        let engine = SearchEngine()
        await engine.update(songs: [song("s", "Echo")])
        await engine.update(playlists: [playlist("p", "Echo")])
        await engine.update(albums: [album("al", "Echo")])
        await engine.update(artists: [artist("ar", "Echo")])
        let found = ids(await search(engine, "echo"))
        #expect(found == ["artist-ar", "album-al", "playlist-p", "song-s"])
    }

    @Test func keepsTheLibrarysOrderAmongTies() async {
        let engine = SearchEngine()
        await engine.update(songs: (0..<50).map { song("s\($0)", "Track \($0)") })
        let found = ids(await search(engine, "track"))
        #expect(found == (0..<50).map { "song-s\($0)" })
    }

    @Test func ignoresCaseAndDiacritics() async {
        let engine = SearchEngine()
        await engine.update(artists: [artist("1", "Beyoncé"), artist("2", "Motörhead")])
        #expect(ids(await search(engine, "BEYONCE")) == ["artist-1"])
        #expect(ids(await search(engine, "motorhead")) == ["artist-2"])
        #expect(ids(await search(engine, "Motörhead")) == ["artist-2"])
    }

    @Test func emptyOrBlankQueryFindsNothing() async {
        let engine = SearchEngine()
        await engine.update(artists: [artist("1", "A")])
        #expect(ids(await search(engine, "")).isEmpty)
        #expect(ids(await search(engine, "   ")).isEmpty)
    }

    @Test func capsTheResultsAndAlignsTheThumbnailRequests() async throws {
        let engine = SearchEngine()
        await engine.update(songs: (0..<100).map { song("s\($0)", "Song \($0)") })
        let outcome = try #require(await search(engine, "song", limit: 10))
        #expect(outcome.items.count == 10)
        #expect(outcome.requests.count == 10)
        // The best come first even past the cap: a prefix match listed after 10 plain "contains" ones.
        await engine.update(songs: (0..<100).map { song("s\($0)", "A Song \($0)") } + [song("best", "Song")])
        #expect(ids(await search(engine, "song", limit: 10)).first == "song-best")
    }

    @Test func requestsMatchEachItem() async throws {
        let engine = SearchEngine()
        await engine.update(artists: [artist("ar", "Echo")])
        await engine.update(albums: [album("al", "Echo")])
        let outcome = try #require(await search(engine, "echo"))
        #expect(outcome.requests.count == 2)
        #expect(outcome.requests[0] == ArtworkRequest.artistRow("ar", scale: 3, points: 56))
        #expect(outcome.requests[1] == ArtworkRequest.albumRow("al", scale: 3, points: 56))
    }

    @Test func narrowingGivesTheSameAnswerAsAFullScan() async {
        let library = (0..<400).map { song("s\($0)", "Song \($0) \($0 % 7 == 0 ? "moon" : "sun")", by: $0 % 3 == 0 ? "Luna" : nil) }
        let narrowed = SearchEngine()
        await narrowed.update(songs: library)
        _ = await search(narrowed, "s")
        _ = await search(narrowed, "so")
        let viaNarrowing = ids(await search(narrowed, "song 1"))

        let fresh = SearchEngine()
        await fresh.update(songs: library)
        #expect(viaNarrowing == ids(await search(fresh, "song 1")))

        // Backspacing (a query that no longer contains the last one) scans everything again.
        let back = ids(await search(narrowed, "so"))
        #expect(back == ids(await search(fresh, "so")))
    }

    @Test func aChangedListInvalidatesNarrowing() async {
        let engine = SearchEngine()
        await engine.update(songs: [song("a", "Moon")])
        #expect(ids(await search(engine, "mo")) == ["song-a"])
        await engine.update(songs: [song("a", "Moon"), song("b", "Moonlight")])
        #expect(ids(await search(engine, "moon")) == ["song-a", "song-b"])
    }

    @Test func updateReportsWhetherTheListChanged() async {
        let engine = SearchEngine()
        let list = [artist("1", "A")]
        #expect(await engine.update(artists: list))
        #expect(await engine.update(artists: list) == false)
        #expect(await engine.update(artists: [artist("1", "B")]))
    }

    @Test func aCancelledSearchReturnsNothing() async {
        let engine = SearchEngine()
        await engine.update(songs: (0..<20_000).map { song("s\($0)", "Song \($0)") })
        let task = Task { () -> SearchOutcome? in
            // Cancelled before it starts scanning.
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.search("song", limit: 10, scale: 3, artworkPoints: 56)
        }
        #expect(await task.value == nil)
    }
}

struct SearchHistoryTests {
    private func makeStore() -> SearchHistoryStore {
        let defaults = UserDefaults(suiteName: "SearchHistoryTests-\(UUID().uuidString)")!
        return SearchHistoryStore(defaults: defaults, key: "history")
    }

    @Test func newestComesFirstAndARepeatMovesUp() async {
        let store = makeStore()
        await store.record("album-1")
        await store.record("song-2")
        await store.record("album-1")
        #expect(await store.recent() == ["album-1", "song-2"])
    }

    @Test func isCapped() async {
        let store = makeStore()
        for n in 0..<(SearchHistoryStore.limit + 10) { await store.record("song-\(n)") }
        let recent = await store.recent()
        #expect(recent.count == SearchHistoryStore.limit)
        #expect(recent.first == "song-\(SearchHistoryStore.limit + 9)")
    }

    @Test func removesAndClears() async {
        let store = makeStore()
        await store.record("a-1")
        await store.record("a-2")
        await store.remove("a-1")
        #expect(await store.recent() == ["a-2"])
        await store.clear()
        #expect(await store.recent().isEmpty)
    }

    @Test func persists() async {
        let defaults = UserDefaults(suiteName: "SearchHistoryTests-\(UUID().uuidString)")!
        await SearchHistoryStore(defaults: defaults, key: "h").record("album-1")
        #expect(await SearchHistoryStore(defaults: defaults, key: "h").recent() == ["album-1"])
    }

    @Test func engineResolvesIdsInOrderAndDropsTheMissing() async {
        let engine = SearchEngine()
        await engine.update(artists: [artist("a-b-c", "Echo")])      // an id with dashes
        await engine.update(albums: [album("al", "Echo")])
        await engine.update(songs: [song("s", "Echo")])
        let outcome = await engine.items(
            matching: ["song-s", "album-gone", "artist-a-b-c", "album-al", "nonsense"], scale: 3, artworkPoints: 56
        )
        #expect(outcome.items.map(\.id) == ["song-s", "artist-a-b-c", "album-al"])
        #expect(outcome.requests.count == 3)
    }
}
