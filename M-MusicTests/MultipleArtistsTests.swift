import Foundation
import Testing
@testable import M_Music

struct MultipleArtistsTests {
    @Test func aSongWithSeveralArtistsIsCommaSeparated() throws {
        let json = #"{"id":"s-1","title":"T","artist":"Daft Punk • Pharrell Williams • Nile Rodgers","created":"2024-01-01T00:00:00Z"}"#
        let song = try JSONDecoder().decode(Child.self, from: Data(json.utf8))
        #expect(song.artist == "Daft Punk, Pharrell Williams, Nile Rodgers")
    }

    @Test func anAlbumWithSeveralArtistsIsCommaSeparated() throws {
        let json = #"{"id":"al-1","name":"A","artist":"One • Two","songCount":1,"duration":1,"created":"2024-01-01T00:00:00Z"}"#
        let album = try JSONDecoder().decode(AlbumID3.self, from: Data(json.utf8))
        #expect(album.artist == "One, Two")
    }

    @Test func aSingleArtistIsLeftAlone() {
        #expect("AC/DC".commaSeparatedArtists == "AC/DC")
        #expect("Earth, Wind & Fire".commaSeparatedArtists == "Earth, Wind & Fire")
    }
}
