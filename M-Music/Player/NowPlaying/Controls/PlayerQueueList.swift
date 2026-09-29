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
        VStack(spacing: 0) {
            // Outside the scroll view, so it stays put while the rows scroll under it.
            buttons
            ScrollView {
                VStack(spacing: 0) {
                    // Scrolls with the rows, so it leaves and enters with the list and needs no
                    // animation of its own.
                    header
                    LazyVStack(spacing: 12) {
                        ForEach(upcoming, id: \.id) { entry in
                            SongRow(track: entry.track, rowArtworkSize: rowArtworkSize, displayScale: displayScale, showsReorderHandle: true)
                        }
                    }
                }
                .padding(.horizontal, NowPlayingLayout.cardPaddings)
                // Room for the edge fades (`FadeMask`), so the first and last rows can rest clear of them.
                .padding(.top, FadeMask.topFade)
                .padding(.bottom, FadeMask.bottomFade)
            }
            .scrollIndicators(.hidden)
            .mask { TopFade() }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The shuffle, repeat and non-stop buttons, sharing the row's width. They don't do anything yet.
    private var buttons: some View {
        HStack(spacing: 8) {
            HeaderButton(symbol: "shuffle")
            HeaderButton(symbol: "repeat")
            HeaderButton(symbol: "infinity")
        }
        .padding(.horizontal, NowPlayingLayout.cardPaddings)
        .padding(.top, 8)
    }

    /// "Up next", and where the queue came from beneath it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up next")
                .font(.headline)
                .foregroundStyle(.white)
            if let sourceName {
                Text("From \(sourceName)")
                    .font(.caption)
                    .foregroundStyle(Color.transparentWhite)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }

    /// Falls back to the current song's album when the queue wasn't started from a screen that
    /// named it (a lone song from a list, or a queue restored after a relaunch).
    private var sourceName: String? {
        player.queueSourceName ?? player.currentTrack?.album
    }

    /// A capsule-shaped, transparent gray button with a symbol, as wide as the row gives it.
    private struct HeaderButton: View {
        let symbol: String

        var body: some View {
            Button {} label: {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.transparentWhite)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.15), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
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
