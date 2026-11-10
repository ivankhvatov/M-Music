import Combine
import Foundation

/// Loads the lyrics for the song that's playing, off the main actor: which song they're for, when
/// the panel is up, fetching them and measuring their layout, and prefetching them while the
/// expanded player is up. Once they're on screen it's `LyricsModel` that keeps them in step with
/// the song, from the player's own position.
///
/// Its inputs arrive as `Event`s, through an `AsyncStream` so they're handled in the order they
/// happened: the track from `LyricsFeed`, and the panel coming and going from the views.
actor LyricsConductor {
    enum Event: Sendable {
        /// The current track changed (`nil`: nothing, or radio). `prefetch`: the expanded player is
        /// up, so its lyrics will probably be asked for soon.
        case track(Child?, prefetch: Bool)
        /// The lyrics panel came up (`width` is the screen's) or went away.
        case activate(Bool, width: CGFloat)
    }

    @MainActor static let shared: LyricsConductor = {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let feed = LyricsFeed(continuation: continuation)
        return LyricsConductor(stream: stream, continuation: continuation, model: .shared, feed: feed)
    }()

    private let model: LyricsModel
    private let continuation: AsyncStream<Event>.Continuation
    /// Held so its subscriptions live as long as this does.
    private let feed: LyricsFeed

    // The panel and the song.
    private var active = false
    private var trackID: String?
    private var currentTrack: Child?
    /// The width the lines' text is laid out in.
    private var textWidth: CGFloat = 300

    private var loadTask: Task<Void, Never>?

    init(stream: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation, model: LyricsModel, feed: LyricsFeed) {
        self.model = model
        self.continuation = continuation
        self.feed = feed
        Task { await self.run(stream) }
    }

    /// Queues an event; callable from anywhere.
    nonisolated func send(_ event: Event) {
        continuation.yield(event)
    }

    private func run(_ stream: AsyncStream<Event>) async {
        for await event in stream { await handle(event) }
    }

    // MARK: - Events

    private func handle(_ event: Event) async {
        switch event {
        case .track(let track, let prefetch): await trackChanged(track, prefetch: prefetch)
        case .activate(let isActive, let width): await activate(isActive, width: width)
        }
    }

    private func trackChanged(_ track: Child?, prefetch: Bool) async {
        guard track?.id.raw != trackID else { return }
        trackID = track?.id.raw
        currentTrack = track
        loadTask?.cancel()
        await model.stopFollowing()
        guard let track else {
            if active { await model.setPhase(.unavailable) }
            return
        }
        if active {
            await begin(track)
        } else if prefetch {
            await LyricsLoader.shared.prefetch(track)
        }
    }

    private func activate(_ isActive: Bool, width: CGFloat) async {
        textWidth = LyricsLayout.textWidth(forViewWidth: width)
        guard active != isActive else { return }
        active = isActive
        if isActive {
            if let currentTrack {
                await begin(currentTrack)
            } else {
                await model.setPhase(.unavailable)
            }
        } else {
            loadTask?.cancel()
            await model.setPhase(.idle)
        }
    }

    /// Gets the track's lyrics onto the screen: at once if they're already fetched, with a spinner
    /// until they are if not.
    private func begin(_ track: Child) async {
        loadTask?.cancel()
        if let cached = await LyricsLoader.shared.cached(for: track) {
            await loaded(cached, trackID: track.id.raw)
            return
        }
        await model.setPhase(.loading)
        loadTask = Task {
            let lyrics = await LyricsLoader.shared.lyrics(for: track)
            guard !Task.isCancelled else { return }
            await self.loaded(lyrics, trackID: track.id.raw)
        }
    }

    private func loaded(_ lyrics: TrackLyrics, trackID id: String) async {
        guard active, id == trackID else { return }
        switch lyrics {
        case .synced(let timeline):
            // Measured here, off the main actor, rather than by the views as they build.
            await model.showSynced(timeline, LyricsLayout(timeline: timeline, textWidth: textWidth))
        case .plain(let text):
            await model.setPhase(.plain(text))
        case .unavailable:
            await model.setPhase(.unavailable)
        }
    }
}

/// Forwards the track the lyrics are for into the conductor's event stream. Set up once.
@MainActor
final class LyricsFeed {
    private var subscriptions = Set<AnyCancellable>()

    init(continuation: AsyncStream<LyricsConductor.Event>.Continuation) {
        let player = PlayerManager.shared

        Publishers.CombineLatest(player.$currentIndex, player.$queue)
            .map { index, queue -> Child? in
                guard let index, queue.indices.contains(index) else { return nil }
                return queue[index]
            }
            // The track the changes come to, not each one on the way: restoring a queue sets the
            // queue and then the index, and between them the track is another song.
            .debounce(for: .milliseconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates { $0?.id == $1?.id }
            .sink { track in
                // While the expanded player is up, the lyrics will probably be asked for.
                let expanded = MainActor.assumeIsolated { PlayerPresentation.shared.expanded }
                continuation.yield(.track(track, prefetch: expanded))
            }
            .store(in: &subscriptions)
    }
}
