import Foundation
import Testing
@testable import M_Music

private func album(_ id: String, cover: String?) -> AlbumID3 {
    AlbumID3(
        id: FlexibleID(id), name: id, artist: nil, artistId: nil, coverArt: cover, songCount: 1, duration: 1,
        playCount: nil, created: nil, starred: nil, year: nil, genre: nil, userRating: nil
    )
}

private func song(_ id: String, cover: String?, albumId: String?) -> Child {
    Child(
        id: FlexibleID(id), title: id, album: nil, artist: nil, track: nil, year: nil, genre: nil,
        coverArt: cover, size: nil, contentType: nil, suffix: nil, duration: nil, bitRate: nil,
        discNumber: nil, starred: nil, albumId: albumId.map { FlexibleID($0) }, artistId: nil, replayGain: nil
    )
}

/// Settings of their own, so a test never changes the app's.
private func settings(useAlbumCover: Bool? = nil) -> UserDefaults {
    let name = "ListArtworkTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    if let useAlbumCover { defaults.set(useAlbumCover, forKey: ArtworkSettings.Keys.useAlbumCoverForSongs) }
    return defaults
}

private func artwork(
    _ defaults: UserDefaults = settings(), cached: [AlbumID3]? = nil, fetched: [AlbumID3]? = nil
) -> ListArtwork {
    ListArtwork(defaults: defaults, cachedCatalog: { cached }, fetchedCatalog: { fetched }, announceDelay: .zero)
}

struct ListArtworkTests {
    private let track = song("s1", cover: "mf-s1", albumId: "a1")

    @Test func aSongsRowShowsItsAlbumsCoverUnlessToldOtherwise() {
        #expect(ArtworkSettings.useAlbumCoverForSongs(settings()))
        let on = artwork()
        on.update(with: [album("a1", cover: "al-a1")])
        #expect(on.artworkId(for: track) == "al-a1")

        let off = artwork(settings(useAlbumCover: false))
        off.update(with: [album("a1", cover: "al-a1")])
        #expect(off.artworkId(for: track) == "mf-s1")
        #expect(off.cover(ofAlbum: "a1") == "al-a1")
    }

    @Test func aSongWhoseAlbumIsNotKnownKeepsItsOwnArtwork() {
        let list = artwork()
        list.update(with: [album("a2", cover: "al-a2"), album("a1", cover: nil)])
        #expect(list.artworkId(for: track) == "mf-s1")
        #expect(list.artworkId(for: song("s2", cover: nil, albumId: "a3")) == "a3")
        #expect(list.artworkId(for: song("s3", cover: "c3", albumId: nil)) == "c3")
    }

    @Test func onlyAWholeCatalogueForgetsAlbumsItDoesNotName() {
        let list = artwork()
        #expect(list.update(with: [album("a1", cover: "one")]))
        #expect(!list.update(with: [album("a1", cover: "one")]))       // nothing new
        #expect(list.update(with: [album("a2", cover: "two")]))
        #expect(list.cover(ofAlbum: "a1") == "one")
        #expect(list.update(with: [album("a2", cover: "two")], isWholeCatalog: true))
        #expect(list.cover(ofAlbum: "a1") == nil)
        #expect(list.update(albumId: "a2", coverArt: "newer"))
        #expect(!list.update(albumId: "a2", coverArt: "newer"))
        #expect(!list.update(albumId: "a2", coverArt: nil))
        #expect(list.cover(ofAlbum: "a2") == "newer")
    }

    @Test func theCachedAlbumListIsEnough() async {
        let list = artwork(cached: [album("a1", cover: "cached")], fetched: [album("a1", cover: "fetched")])
        await list.prepare()
        #expect(list.artworkId(for: track) == "cached")
    }

    @Test func withNothingCachedTheAlbumListIsFetched() async {
        let list = artwork(fetched: [album("a1", cover: "fetched")])
        await list.prepare()
        #expect(list.artworkId(for: track) == "fetched")
    }

    @Test func aSlowServerDoesNotHoldTheListAndItsAnswerStillApplies() async throws {
        // The server answers when the test says so — and in any case after a while, so that a list
        // that did wait fails the test rather than hanging it.
        let (answer, send) = AsyncStream.makeStream(of: Void.self)
        let list = ListArtwork(
            defaults: settings(),
            cachedCatalog: { nil },
            fetchedCatalog: {
                for await _ in answer {}
                return [album("a1", cover: "late")]
            },
            announceDelay: .zero
        )
        let givingUp = Task {
            try await Task.sleep(for: .seconds(20))
            send.finish()
        }
        await list.prepare(limit: .milliseconds(50))
        #expect(list.artworkId(for: track) == "mf-s1")     // back before the server answered
        send.finish()
        givingUp.cancel()
        for _ in 0..<500 where list.artworkId(for: track) != "late" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(list.artworkId(for: track) == "late")
    }

    @Test func changingTheSettingChangesWhatRowsShow() {
        let defaults = settings()
        let list = artwork(defaults)
        list.update(with: [album("a1", cover: "al-a1")])
        defaults.set(false, forKey: ArtworkSettings.Keys.useAlbumCoverForSongs)
        list.settingChanged()
        #expect(list.artworkId(for: track) == "mf-s1")
        defaults.set(true, forKey: ArtworkSettings.Keys.useAlbumCoverForSongs)
        list.settingChanged()
        #expect(list.artworkId(for: track) == "al-a1")
    }

    @Test func anotherServerStartsFromNothing() {
        let list = artwork()
        list.update(with: [album("a1", cover: "al-a1")], isWholeCatalog: true)
        list.reset()
        #expect(list.artworkId(for: track) == "mf-s1")
    }
}
