import Foundation
import SwiftUI

class Song {
    let id = UUID()
    
    let title: String
    let artist: String
    let albumArtist: String
    
    let genre: String?
    let releaseYear: Int?
    let isLossless: Bool
    let codec: String?
    
    let trackNumber: Int?
    let discNumber: Int?
    
    let artwork: Image
    
    var isDownloaded: Bool = false
    
    init(title: String, artist: String, albumArtist: String, genre: String?, releaseYear: Int?, isLossless: Bool, codec: String?, trackNumber: Int?, discNumber: Int?, artwork: Image) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.genre = genre
        self.releaseYear = releaseYear
        self.isLossless = isLossless
        self.codec = codec
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artwork = artwork
    }
    
    public func Download() {
        isDownloaded = true
    }
    
    public func Delete() {
        isDownloaded = false
    }
}
