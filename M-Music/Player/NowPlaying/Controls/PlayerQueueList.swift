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
        .environment(\.colorScheme, .dark)
        // The rows' menu buttons would otherwise pick up the default blue accent.
        .tint(Color.transparentWhite)
    }

    /// Fades whatever it masks out over the top and bottom few points of its own frame, instead of
    /// cutting it off hard. Applied by `RegularChrome` to the list's *container* rather than to the
    /// list itself, so the fades stay put — the bottom one ending exactly on the scrubber's top edge
    /// — while the list slides in or out behind them.
    struct FadeMask: View {
        static let topFade: CGFloat = 20
        static let bottomFade: CGFloat = 56

        var body: some View {
            GeometryReader { geometry in
                // Fixed point sizes turned into gradient locations. They're clamped so the two
                // fades never overlap — the frame is far shorter than both while the list is
                // still sliding in or out.
                let height = max(geometry.size.height, 1)
                let topEnd = min(Self.topFade / height, 0.5)
                let bottomStart = max(1 - Self.bottomFade / height, topEnd)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: topEnd),
                        .init(color: .black, location: bottomStart),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
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
