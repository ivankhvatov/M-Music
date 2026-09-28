import SwiftUI

/// The up-next list shown in the expanded player while the queue toggle is on: every track after
/// the current one, as the same `SongRow`s the song lists use — on a transparent background, so the
/// player's backdrop shows through, and forced to the dark color scheme so the rows' primary/
/// secondary text reads as white over it.
struct PlayerQueueList: View {
    @ObservedObject private var player = PlayerManager.shared
    @Environment(\.displayScale) private var displayScale

    private let rowArtworkSize: CGFloat = 44

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(upcoming, id: \.id) { entry in
                    SongRow(track: entry.track, rowArtworkSize: rowArtworkSize, displayScale: displayScale)
                }
            }
            .padding(.horizontal, NowPlayingLayout.cardPaddings)
            // Room for the edge fades (`FadeMask`), so the first and last rows can rest clear of them.
            .padding(.top, FadeMask.topFade)
            .padding(.bottom, FadeMask.bottomFade)
        }
        .scrollIndicators(.hidden)
        .mask { TopFade() }
        .environment(\.colorScheme, .dark)
        // The rows' menu buttons would otherwise pick up the default blue accent.
        .tint(Color.transparentWhite)
    }

    /// Fades the bottom `bottomFade` points of whatever it masks out, instead of cutting it off
    /// hard. Applied by `RegularChrome` to the list's *container* rather than to the list itself,
    /// so the fade stays put — ending exactly on the scrubber's top edge — while the list slides
    /// in or out behind it. Fixed-size pieces only, so nothing in it depends on the size it's
    /// given and it needn't be redrawn when that changes.
    struct BottomFade: View {
        var body: some View {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: FadeMask.bottomFade)
            }
        }
    }

    /// The top-edge counterpart, for the list's own mask.
    struct TopFade: View {
        var body: some View {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: FadeMask.topFade)
                Rectangle()
            }
        }
    }

    /// The fade sizes, shared with the list's padding so its first and last rows rest clear of them.
    enum FadeMask {
        static let topFade: CGFloat = 20
        static let bottomFade: CGFloat = 56
    }

    /// The tracks after the current one. Each gets an id from its track id plus how many times that
    /// track has already appeared above it (a queue can hold the same song twice) — stable as
    /// playback advances, which `SongRow` needs: it resolves its artwork URL once, in `init`.
    private var upcoming: [Entry] {
        guard let currentIndex = player.currentIndex, player.queue.indices.contains(currentIndex) else { return [] }
        var seen: [String: Int] = [:]
        return player.queue[(currentIndex + 1)...].map { track in
            let occurrence = seen[track.id.raw, default: 0]
            seen[track.id.raw] = occurrence + 1
            return Entry(id: "\(track.id.raw)#\(occurrence)", track: track)
        }
    }

    private struct Entry {
        let id: String
        let track: Child
    }
}
