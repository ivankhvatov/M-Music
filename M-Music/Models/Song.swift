import Foundation
import SwiftUI

class Song {
    let id = UUID()
    
    let title: String
    let artist: [String]
    let albumArtist: [String]
    
    let genre: String?
    let releaseYear: Int?
    let isLossless: Bool
    let codec: String?
    
    let trackNumber: Int?
    let discNumber: Int?
    
    let artwork: Image
    
    let duration: Duration
    
    var isFavorite: Bool = false
    var isDownloaded: Bool = false
    
    init(title: String, artist: String, albumArtist: String, genre: String?, releaseYear: Int?, isLossless: Bool, codec: String?, trackNumber: Int?, discNumber: Int?, artwork: Image, duration: Duration, isFavorite: Bool, isDownloaded: Bool) {
        self.title = title
        self.artist = artist.components(separatedBy: "; ")
        self.albumArtist = albumArtist.components(separatedBy: "; ")
        self.genre = genre
        self.releaseYear = releaseYear
        self.isLossless = isLossless
        self.codec = codec
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artwork = artwork
        self.duration = duration
        self.isFavorite = isFavorite
        self.isDownloaded = isDownloaded
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
