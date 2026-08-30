import Foundation
import SwiftUI

class Album {
    let id: UUID
    
    let title: String
    let artist: String
    let edition: String?
    
    let genre: String?
    let releaseYear: Int?
    let isLossless: Bool
    let codec: String?
    
    let artwork: Image
    let tracks: [Song]
    
    init(id: UUID, title: String, artist: String, edition: String?, genre: String?, releaseYear: Int?, isLossless: Bool, codec: String?, artwork: Image, tracks: [Song]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.edition = edition
        self.genre = genre
        self.releaseYear = releaseYear
        self.isLossless = isLossless
        self.codec = codec
        self.artwork = artwork
        self.tracks = tracks
    }
}
