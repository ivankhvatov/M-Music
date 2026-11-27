import SwiftUI
import Testing
import UIKit
@testable import M_Music

private let textSizes: [(UIContentSizeCategory, DynamicTypeSize)] = [
    (.extraSmall, .xSmall), (.small, .small), (.medium, .medium), (.large, .large), (.extraLarge, .xLarge),
    (.extraExtraLarge, .xxLarge), (.extraExtraExtraLarge, .xxxLarge), (.accessibilityMedium, .accessibility1),
    (.accessibilityLarge, .accessibility2), (.accessibilityExtraLarge, .accessibility3),
    (.accessibilityExtraExtraLarge, .accessibility4), (.accessibilityExtraExtraExtraLarge, .accessibility5),
]

private func song(_ title: String, by artist: String?) -> Child {
    Child(
        id: FlexibleID("SongTableCellTests"), title: title, album: nil, artist: artist, track: nil, year: nil,
        genre: nil, coverArt: nil, size: nil, contentType: nil, suffix: nil, duration: nil, bitRate: nil,
        discNumber: nil, starred: nil, albumId: nil, artistId: nil, replayGain: nil
    )
}

/// The Songs screen draws its rows with UIKit; every other list of songs uses `SongRow`.
@MainActor
struct SongTableCellTests {
    @Test func aRowIsAsTallAsASongRowAtEveryTextSize() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.isHidden = false
        defer { window.isHidden = true }
        let width: CGFloat = 402
        let songs = [
            song("Amber", by: "Sky Paper 6"),
            song("Amber", by: nil),
            song(
                "A much longer song title that has to wrap onto further lines of its row",
                by: "An artist with a long name that wraps as well, and then some more"
            ),
        ]
        for (category, textSize) in textSizes {
            window.traitOverrides.preferredContentSizeCategory = category
            for track in songs {
                let cell = SongTableCell(frame: CGRect(x: 0, y: 0, width: width, height: 60))
                window.addSubview(cell)
                defer { cell.removeFromSuperview() }
                cell.updateTraitsIfNeeded()
                cell.show(track, artworkURL: nil, isAvailable: true, download: .none)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 1, section: 0))
                attributes.size = CGSize(width: width, height: 60)
                let height = cell.preferredLayoutAttributesFitting(attributes).size.height

                let scale = cell.traitCollection.displayScale
                let row = SongRow(
                    track: track, rowArtworkSize: SongTableCell.artworkSide, displayScale: scale,
                    showsGoToActions: true, showsAddToPlaylist: true
                )
                .environment(\.dynamicTypeSize, textSize)
                .environment(\.displayScale, scale)
                let hosted = UIHostingController(rootView: row)
                    .sizeThatFits(in: CGSize(width: width - 2 * SongTableCell.sideInset, height: 10_000))
                // A `List` row has 6 points above and below its content.
                #expect(
                    abs(height - (hosted.height + 12)) < 0.05,
                    "\(category.rawValue), \(track.title.prefix(8)), artist \(track.artist != nil)"
                )
            }
        }
    }
}
