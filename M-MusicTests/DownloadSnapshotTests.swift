import Foundation
import Testing
@testable import M_Music

private func record(
    _ id: String, title: String = "T", artist: String? = "A", album: String? = "Album", albumId: String? = "al-1",
    track: Int? = 1, bytes: Int64 = 10
) -> DownloadRecord {
    DownloadRecord(
        songId: id, title: title, artist: artist, album: album, albumId: albumId, coverArt: nil, track: track,
        discNumber: nil, duration: nil, year: nil, genre: nil, filePath: "/x/\(id).flac", fileExtension: "flac",
        contentType: nil, bitRate: nil, byteSize: bytes, replayGainTrackGain: nil, replayGainAlbumGain: nil,
        addedAt: Date(timeIntervalSince1970: 0), format: nil
    )
}

struct DownloadSnapshotTests {
    @Test func derivesPerAlbumCountsArtistsAndIds() {
        let snapshot = DownloadSnapshot(records: [
            record("s1", artist: "X", albumId: "al-1"),
            record("s2", artist: "X", albumId: "al-1"),
            record("s3", artist: "Y", albumId: "al-2"),
            record("s4", artist: nil, albumId: nil),
        ], totalBytes: 40)
        #expect(snapshot.songIds == ["s1", "s2", "s3", "s4"])
        #expect(snapshot.songCountByAlbumId == ["al-1": 2, "al-2": 1])
        #expect(snapshot.artistNames == ["X", "Y"])
    }

    @Test func groupsByAlbumSortedByTitleAndTracksInOrder() {
        let snapshot = DownloadSnapshot(records: [
            record("b2", album: "Beta", albumId: "b", track: 2),
            record("a1", album: "Alpha", albumId: "a", track: 1),
            record("b1", album: "Beta", albumId: "b", track: 1),
        ], totalBytes: 0)
        #expect(snapshot.recordsByAlbum.map(\.albumTitle) == ["Alpha", "Beta"])
        #expect(snapshot.recordsByAlbum[1].records.map(\.songId) == ["b1", "b2"])
    }

    @Test func equalityOnlyLooksAtTheInputs() {
        let a = DownloadSnapshot(records: [record("s1")], totalBytes: 10)
        let b = DownloadSnapshot(records: [record("s1")], totalBytes: 10)
        #expect(a == b)
        #expect(a != DownloadSnapshot(records: [record("s1"), record("s2")], totalBytes: 20))
        #expect(a != DownloadSnapshot(records: [record("s1")], totalBytes: 11))
    }
}
