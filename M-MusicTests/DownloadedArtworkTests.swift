import Foundation
import Testing
@testable import M_Music

private func record(
    _ id: String, coverArt: String? = nil, albumId: String? = "al-1", artistId: String? = nil
) -> DownloadRecord {
    DownloadRecord(
        songId: id, title: "T", artist: "A", album: "Al", albumId: albumId, coverArt: coverArt, track: 1,
        discNumber: nil, duration: nil, year: nil, genre: nil, filePath: "/x/\(id).flac", fileExtension: "flac",
        contentType: nil, bitRate: nil, byteSize: 1, replayGainTrackGain: nil, replayGainAlbumGain: nil,
        addedAt: Date(timeIntervalSince1970: 0), format: nil, artistId: artistId
    )
}

struct DownloadedArtworkTests {
    @Test func aDownloadedSongSavesItsSongAlbumArtistAndPlaylistArtwork() {
        let targets = DownloadedArtwork.targets(
            records: [record("s1", coverArt: "mf-s1", albumId: "al-1", artistId: "ar-1")],
            albums: ["al-1": .init(coverArt: "al-1_abc", artistId: "ar-9")],
            artists: ["ar-1": "ar-1_xyz"],
            playlistArtwork: ["pl-1_q"]
        )
        #expect(targets.songs == ["mf-s1"])
        #expect(targets.albums == ["al-1_abc"])
        #expect(targets.artists == ["ar-1_xyz"])      // the song's own artist, not the album's
        #expect(targets.playlists == ["pl-1_q"])
    }

    @Test func songArtworkFallsBackToTheAlbumThenTheSong() {
        let targets = DownloadedArtwork.targets(
            records: [record("s1", coverArt: nil, albumId: "al-1"), record("s2", coverArt: nil, albumId: nil)],
            albums: [:], artists: [:], playlistArtwork: []
        )
        #expect(targets.songs == ["al-1", "s2"])
    }

    @Test func anOlderDownloadTakesItsArtistFromItsAlbum() {
        let records = [record("s1", albumId: "al-1", artistId: nil)]
        let albums = ["al-1": DownloadedArtwork.AlbumInfo(coverArt: nil, artistId: "ar-5")]
        #expect(DownloadedArtwork.artistIds(in: records, albums: albums) == ["ar-5"])
        let targets = DownloadedArtwork.targets(records: records, albums: albums, artists: ["ar-5": "ar-5"], playlistArtwork: [])
        #expect(targets.artists == ["ar-5"])
        #expect(targets.albums == ["al-1"])             // no cover id of its own: the album id itself
    }

    @Test func unresolvedAlbumsAndArtistsAreSkippedRatherThanGuessed() {
        let targets = DownloadedArtwork.targets(
            records: [record("s1", coverArt: "c1", albumId: "al-1", artistId: "ar-1")],
            albums: [:], artists: [:], playlistArtwork: []
        )
        #expect(targets.albums.isEmpty)
        #expect(targets.artists.isEmpty)
        #expect(targets.songs == ["c1"])
    }

    @Test func eachIdGetsItsFullImageAndItsRowThumbnailAtTheRightSize() {
        var targets = DownloadedArtwork.Targets()
        targets.songs = ["a"]
        targets.albums = ["b"]
        targets.playlists = ["c"]
        targets.artists = ["d"]
        let urls = targets.urls(scale: 3) { id, size in
            URL(string: "http://x.test/\(id)?size=\(size.map(String.init) ?? "full")")
        }
        #expect(urls.map(\.absoluteString) == [
            "http://x.test/a?size=full", "http://x.test/a?size=132",     // song rows: 44pt
            "http://x.test/b?size=full", "http://x.test/b?size=192",     // album rows: 64pt
            "http://x.test/c?size=full", "http://x.test/c?size=192",     // playlist rows: 64pt
            "http://x.test/d?size=full", "http://x.test/d?size=144",     // artist rows: 48pt
        ])
    }

    @Test func theSameImageIsNeverListedTwice() {
        var targets = DownloadedArtwork.Targets()
        targets.songs = ["a"]
        targets.albums = ["a"]          // an album's songs usually share its cover
        let urls = targets.urls(scale: 3) { id, size in
            URL(string: "http://x.test/\(id)?size=\(size.map(String.init) ?? "full")")
        }
        // full once; the 44pt and 64pt thumbnails differ.
        #expect(urls.count == 3)
    }
}
