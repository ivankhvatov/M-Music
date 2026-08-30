import Foundation
import SwiftUI

class TestModels {
    static let album: Album = {
        let album = makeAlbum()
        album.tracks[0].Download()
        album.tracks[2].Download()
        return album
    }()

    private static func makeAlbum() -> Album {
        Album(
            id: UUID(),
            title: "Too Fast to Die",
            artist: "Archspire",
            edition: nil,
            genre: "Death Metal",
            releaseYear: 2026,
            isLossless: true,
            codec: "FLAC",
            artwork: Image("cover_placeholder"),
            tracks: [
            Song(
                title: "Liminal Cypher",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 1,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Red Goliath",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 2,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Carrion Ladder",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 3,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Anomalous Descent",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 4,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "The Vessel",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 5,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Limb of Leviticus",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 6,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Deadbolt the Backward",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 7,
                discNumber: 1,
                artwork: Image("cover_placeholder")
            ),
            Song(
                title: "Too Fast to Die",
                artist: "Archspire",
                albumArtist: "Archspire",
                genre: "Death Metal",
                releaseYear: 2026,
                isLossless: true,
                codec: "FLAC",
                trackNumber: 8,
                discNumber: 1,
                artwork: Image("cover_placeholder")
                ),
            ]
        )
    }
}
