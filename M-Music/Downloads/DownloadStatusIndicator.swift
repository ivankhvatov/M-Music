import SwiftUI

/// Marks a track's download status inline in a row — a filled download glyph once it's on
/// disk, or a small circular progress ring while a download is queued/in flight. Shown to the
/// left of the track's `Menu` in `SongsListView`/`AlbumView`.
struct DownloadStatusIndicator: View {
    let state: DownloadState

    var body: some View {
        switch state {
        case .completed:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        case .queued:
            ProgressRing(progress: 0)
        case .downloading(let progress):
            ProgressRing(progress: progress)
        case .none, .failed:
            EmptyView()
        }
    }

    /// A determinate circular progress indicator — SwiftUI's `ProgressView` with
    /// `.circular` style shows the standard indeterminate spinner on iOS regardless of `value`,
    /// so an actual progress ring needs to be drawn by hand.
    private struct ProgressRing: View {
        let progress: Double

        var body: some View {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    // A thin stub stays visible even at 0 progress, so "queued" doesn't look
                    // like nothing is there at all.
                    .trim(from: 0, to: max(0.03, min(progress, 1)))
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
        }
    }
}
