import Foundation
import SwiftUI

class Album {
    let id: UUID
    
    let title: String
    let artist: [String]
    let edition: String?
    
    let genre: String?
    let releaseYear: Int?
    let isLossless: Bool
    let codec: String?
    
    let label: String?
    
    let artwork: Image
    let duration: Duration
    let tracks: [Song]
    
    var isFavorite: Bool = false
    var isDownloaded: Bool = false
    
    init(id: UUID, title: String, artist: String, edition: String?, genre: String?, releaseYear: Int?, isLossless: Bool, codec: String?, label: String?, artwork: Image, duration: Duration, tracks: [Song], isFavorite: Bool, isDownloaded: Bool) {
        self.id = id
        self.title = title
        self.artist = artist.components(separatedBy: "; ")
        self.edition = edition
        self.genre = genre
        self.releaseYear = releaseYear
        self.isLossless = isLossless
        self.codec = codec
        self.label = label
        self.artwork = artwork
        self.duration = duration
        self.isFavorite = isFavorite
        self.isDownloaded = isDownloaded
        self.tracks = tracks
    }
    
    public func Download() {
        isDownloaded = true
    }
    
    public func Delete() {
        isDownloaded = false
    }
    
    public func ToggleFavorite() {
        isFavorite.toggle()
    }
}
