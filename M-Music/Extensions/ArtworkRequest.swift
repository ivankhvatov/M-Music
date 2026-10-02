import Foundation
import UIKit

/// One image a screen asks `ImageCache` for: which cover (`id`), which server-side thumbnail of it
/// (`size`, `nil` = the original) and which decode tier (`maxPixelSize`, `nil` = full resolution).
///
/// Every screen builds the request for each of its images through the constructors below, and
/// `ImageWarmer` builds the same ones to decode images *before* a screen opens — so the two can
/// never disagree about the cache key (the stable URL plus the tier), which would make a warm-up
/// useless. It's `Codable` so a screen can record what it last showed (see
/// `ImageWarmer.remember`) and have that warmed again after the next launch.
struct ArtworkRequest: Hashable, Codable, Sendable {
    let id: String
    var size: Int?
    var maxPixelSize: Int?

    /// The signed URL — memoized per `(id, size)`, so building it is cheap and always the same one
    /// a view would use.
    var url: URL? { SubsonicClient.shared.cachedCoverArtURL(forId: id, size: size) }

    // MARK: Albums

    /// A grid card (`AlbumCardView`): the original image at the card tier. It's also the stand-in
    /// the album's header shows while its own, larger decode is still running.
    static func albumCard(_ artworkId: String) -> ArtworkRequest {
        ArtworkRequest(id: artworkId, size: nil, maxPixelSize: ImageCache.cardMaxPixelSize)
    }

    /// A list row (`AlbumsListView.AlbumRow`): the server's row-sized thumbnail.
    static func albumRow(_ artworkId: String, scale: CGFloat) -> ArtworkRequest {
        ArtworkRequest(
            id: artworkId,
            size: ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.album, scale: scale),
            maxPixelSize: ImageCache.standardMaxPixelSize
        )
    }

    /// The header of the album screen.
    static func albumHeader(_ artworkId: String) -> ArtworkRequest {
        ArtworkRequest(id: artworkId, size: nil, maxPixelSize: ImageCache.standardMaxPixelSize)
    }

    // MARK: Playlists

    static func playlistCard(_ artworkId: String) -> ArtworkRequest { albumCard(artworkId) }

    static func playlistRow(_ artworkId: String, scale: CGFloat) -> ArtworkRequest {
        ArtworkRequest(
            id: artworkId,
            size: ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.playlist, scale: scale),
            maxPixelSize: ImageCache.standardMaxPixelSize
        )
    }

    static func playlistHeader(_ artworkId: String) -> ArtworkRequest { albumHeader(artworkId) }

    // MARK: Artists

    static func artistRow(_ artworkId: String, scale: CGFloat) -> ArtworkRequest {
        ArtworkRequest(
            id: artworkId,
            size: ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.artist, scale: scale),
            maxPixelSize: ImageCache.avatarMaxPixelSize
        )
    }

    static func artistHeader(_ artworkId: String) -> ArtworkRequest {
        ArtworkRequest(id: artworkId, size: nil, maxPixelSize: ImageCache.cardMaxPixelSize)
    }

    // MARK: Songs and Now Playing

    /// A song row (`SongRow`).
    static func songRow(_ artworkId: String, scale: CGFloat) -> ArtworkRequest {
        ArtworkRequest(
            id: artworkId,
            size: ImageCache.RowArtwork.pixels(ImageCache.RowArtwork.song, scale: scale),
            maxPixelSize: ImageCache.standardMaxPixelSize
        )
    }

    /// The artwork of the mini player and the expanded player (`TrackArtworkView`): full resolution.
    static func nowPlaying(_ artworkId: String) -> ArtworkRequest {
        ArtworkRequest(id: artworkId, size: nil, maxPixelSize: nil)
    }

    /// What the expanded player samples its gradient colours from.
    static func colorSampling(_ artworkId: String) -> ArtworkRequest {
        ArtworkRequest(id: artworkId, size: nil, maxPixelSize: ImageCache.colorSamplingMaxPixelSize)
    }

    /// The id a song's artwork is requested by — the same fallback chain `SongRow` and Now Playing use.
    static func artworkId(of track: Child) -> String {
        track.coverArt ?? track.albumId?.raw ?? track.id.raw
    }
}
