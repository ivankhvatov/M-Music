import Foundation
import Testing
@testable import M_Music

private actor Published {
    var updates: [LibraryCacheIndex.Update] = []
    func add(_ update: LibraryCacheIndex.Update) { updates.append(update) }
}

private func makeIndex(_ log: Published) -> LibraryCacheIndex {
    LibraryCacheIndex(debounce: .milliseconds(30)) { update in await log.add(update) }
}

struct LibraryCacheIndexTests {
    @Test func aBurstOfChangesIsPublishedOnce() async {
        let log = Published()
        let index = makeIndex(log)
        for i in 0..<50 { await index.setAlbumIds(["a\(i)"], forArtist: "ar-\(i)") }
        await index.setSongIds(["s1"], forPlaylist: "pl")
        try? await Task.sleep(for: .milliseconds(200))
        let updates = await log.updates
        #expect(updates.count == 1)
        #expect(updates[0].albumIdsByArtistId?.count == 50)
        #expect(updates[0].songIdsByPlaylistId == ["pl": ["s1"]])
        #expect(updates[0].albumSongCounts == nil)
    }

    @Test func unchangedValuesPublishNothing() async {
        let log = Published()
        let index = makeIndex(log)
        await index.setSongIds(["s1"], forPlaylist: "pl")
        await index.flush()
        await index.setSongIds(["s1"], forPlaylist: "pl")
        await index.flush()
        #expect(await log.updates.count == 1)
    }

    @Test func mergingSummaryOnlyReportsWhatChanged() async {
        let log = Published()
        let index = makeIndex(log)
        var summary = LibraryCacheDatabase.Summary()
        summary.albumSongCounts = ["al-1": 10]
        await index.merge(summary)
        await index.flush()
        // Same counts again, plus a new artist mapping: only the latter is reported.
        summary.albumIdsByArtistId = ["ar-1": ["al-1"]]
        await index.merge(summary)
        await index.flush()
        let updates = await log.updates
        #expect(updates.count == 2)
        #expect(updates[0].albumSongCounts == ["al-1": 10])
        #expect(updates[1].albumSongCounts == nil)
        #expect(updates[1].albumIdsByArtistId == ["ar-1": ["al-1"]])
    }
}
