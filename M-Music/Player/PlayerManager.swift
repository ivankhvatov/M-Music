import Foundation
import AVFoundation

/// Owns playback of the current queue via a single `AVPlayer`, streaming each track from the
/// Subsonic server through `SubsonicClient.streamURL(forId:)`. Shared across the app (mini
/// player, full-screen player, and whatever starts playback) the same way `SubsonicClient` is.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    /// The active play queue: the track that was tapped, followed by the tracks queued after it.
    @Published private(set) var queue: [Child] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Same id `AlbumView`/`AlbumCardView` use for cover art (original size, no `size` param),
    /// so the mini/full player reuses whatever's already in `ImageCache` instead of re-fetching.
    /// Recomputed once per track load rather than on every access: `SubsonicClient.url(for:_:)`
    /// signs each call with a fresh random token, so a computed property here would return a
    /// different URL string on every read even for the same track — defeating both
    /// `CachedAsyncImage`'s change detection and `ImageCache`'s no-op-on-same-url fast path.
    @Published private(set) var artworkURL: URL?

    var currentTrack: Child? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private let client: SubsonicClient
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var didConfigureAudioSession = false

    init(client: SubsonicClient = .shared) {
        self.client = client
    }

    /// Starts streaming `track` immediately and replaces the rest of the queue with
    /// `queueTracks` (typically "everything after this track in the album").
    func play(track: Child, queue queueTracks: [Child] = []) {
        queue = [track] + queueTracks
        currentIndex = 0
        loadCurrentItem(autoplay: true)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func next() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            self.currentIndex = nextIndex
            loadCurrentItem(autoplay: true)
        } else {
            player?.pause()
            player?.seek(to: .zero)
            currentTime = 0
            isPlaying = false
        }
    }

    func previous() {
        guard let currentIndex else { return }
        // Scrubbed past the first few seconds: restart the current track, like most players.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let previousIndex = currentIndex - 1
        if queue.indices.contains(previousIndex) {
            self.currentIndex = previousIndex
            loadCurrentItem(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    private func loadCurrentItem(autoplay: Bool) {
        configureAudioSessionIfNeeded()

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        guard let track = currentTrack, let url = try? client.streamURL(forId: track.id.raw) else {
            isPlaying = false
            return
        }

        let artId = track.coverArt ?? track.albumId?.raw ?? track.id.raw
        artworkURL = try? client.coverArtURL(forId: artId)

        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor in self?.currentTime = time.seconds }
            }
        }

        duration = TimeInterval(track.duration ?? 0)
        currentTime = 0

        if autoplay {
            player?.play()
            isPlaying = true
        }
    }

    private func configureAudioSessionIfNeeded() {
        guard !didConfigureAudioSession else { return }
        didConfigureAudioSession = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
