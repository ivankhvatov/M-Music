import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Owns playback of the current queue via a single `AVPlayer`, streaming each track from the
/// Subsonic server through `SubsonicClient.streamURL(forId:)`. Shared across the app (mini
/// player, full-screen player, and whatever starts playback) the same way `SubsonicClient` is.
///
/// Supports background playback (a `.playback` audio session plus the `audio` background mode,
/// with lock screen / Control Center integration via `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`), near-gapless transitions between tracks (the next track's
/// `AVPlayerItem` is built — and so starts buffering — ahead of time, then swapped in directly
/// instead of being built fresh once the current one ends), and persists the current queue,
/// track, and position across launches.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    /// The full play queue, e.g. an album's track list. `currentIndex` points into it, so tracks
    /// before it are playback history (reachable via `previous()`) and tracks after it play next.
    @Published private(set) var queue: [Child] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Whether the current track is starred, kept in sync with the lock screen / Control
    /// Center's "favorite" toggle (`MPRemoteCommandCenter.likeCommand`) as well as `PlayerView`'s
    /// own star button — both call `toggleStarred()` below.
    @Published private(set) var isCurrentTrackStarred = false
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
    private var backgroundObserver: NSObjectProtocol?
    private var didConfigureAudioSession = false

    /// The next track's item, built ahead of time so it's already buffering when the current
    /// track ends — swapping it straight in (instead of building a fresh item at that point) is
    /// what makes the transition gapless rather than a beat of silence while it loads.
    private var preparedItem: AVPlayerItem?
    private var preparedIndex: Int?

    /// Throttles how often playback position is written to disk — every time-observer tick would
    /// mean a disk write twice a second for as long as something is playing.
    private var ticksSincePersist = 0

    init(client: SubsonicClient = .shared) {
        self.client = client
        restorePersistedState()
        configureRemoteCommandCenter()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistState() }
        }
    }

    /// Starts streaming the track at `index` in `newQueue`. Tracks before it become playback
    /// history (reachable via `previous()`); tracks after it play next — e.g. pass an album's
    /// full track list and the tapped track's index to queue the rest of the album.
    func play(queue newQueue: [Child], startAt index: Int) {
        guard newQueue.indices.contains(index) else { return }
        queue = newQueue
        currentIndex = index
        clearPreparedItem()
        loadCurrentItem(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func next() {
        advance(autoplay: true)
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
            clearPreparedItem()
            loadCurrentItem(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    /// Inserts `track` right after the currently playing one, so it plays next — or starts
    /// playing it immediately if nothing is queued yet.
    func playNext(_ track: Child) {
        guard let currentIndex else {
            play(queue: [track], startAt: 0)
            return
        }
        queue.insert(track, at: currentIndex + 1)
        // The prepared item (if any) was built for whatever used to sit at `currentIndex + 1`,
        // which has now shifted one slot later — rebuild it against the newly-inserted track.
        clearPreparedItem()
        prepareNextItem()
        persistState()
    }

    /// Appends `track` to the end of the queue — or starts playing it immediately if nothing is
    /// queued yet.
    func addToQueue(_ track: Child) {
        guard currentIndex != nil else {
            play(queue: [track], startAt: 0)
            return
        }
        queue.append(track)
        // The queue may have just been exhausted (nothing left to prepare), in which case this
        // newly-appended track is now the one that should be buffering ahead of time.
        if preparedItem == nil {
            prepareNextItem()
        }
        persistState()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        updateNowPlayingPlaybackState()
        persistState()
    }

    /// Stars/unstars the current track. Shared by `PlayerView`'s star button and the lock
    /// screen / Control Center "favorite" toggle, so both stay in sync and do the same thing.
    func toggleStarred() {
        guard let track = currentTrack else { return }
        let newValue = !isCurrentTrackStarred
        isCurrentTrackStarred = newValue
        updateNowPlayingFeedback()
        Task {
            do {
                if newValue {
                    try await client.star(ids: [track.id.raw])
                } else {
                    try await client.unstar(ids: [track.id.raw])
                }
            } catch {
                await MainActor.run {
                    guard currentTrack?.id == track.id else { return }
                    isCurrentTrackStarred = !newValue
                    updateNowPlayingFeedback()
                }
            }
        }
    }

    // MARK: - Playback control

    private func resume() {
        guard currentTrack != nil else { return }
        guard let player else {
            // Lazily restored from a previous session: nothing's been streamed yet, so build the
            // item now and pick up from the restored `currentTime`.
            loadCurrentItem(autoplay: true, startTime: currentTime)
            return
        }
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
        persistState()
    }

    private func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
        persistState()
    }

    private func advance(autoplay: Bool) {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            finishQueue()
            return
        }
        self.currentIndex = nextIndex
        if preparedIndex == nextIndex, let item = preparedItem {
            preparedItem = nil
            preparedIndex = nil
            installItem(item, autoplay: autoplay, startTime: 0)
        } else {
            loadCurrentItem(autoplay: autoplay)
        }
    }

    /// Reached the end of the queue: rewind to the first track and stop, like Apple Music.
    private func finishQueue() {
        clearPreparedItem()
        if queue.isEmpty {
            currentIndex = nil
            player?.pause()
            isPlaying = false
        } else {
            currentIndex = 0
            loadCurrentItem(autoplay: false)
        }
        persistState()
    }

    // MARK: - Item loading

    private func loadCurrentItem(autoplay: Bool, startTime: TimeInterval = 0) {
        configureAudioSessionIfNeeded()
        guard let track = currentTrack, let url = try? client.streamURL(forId: track.id.raw) else {
            isPlaying = false
            return
        }
        installItem(AVPlayerItem(url: url), autoplay: autoplay, startTime: startTime)
    }

    private func installItem(_ item: AVPlayerItem, autoplay: Bool, startTime: TimeInterval) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance(autoplay: true) }
        }

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor in self?.handleTimeUpdate(time.seconds) }
            }
        }

        duration = TimeInterval(currentTrack?.duration ?? 0)
        currentTime = startTime
        if startTime > 0 {
            player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }

        updateArtworkURL()
        updateNowPlayingInfo()
        prepareNextItem()

        if autoplay {
            player?.play()
            isPlaying = true
        } else {
            player?.pause()
            isPlaying = false
        }
        updateNowPlayingPlaybackState()
        persistState()
    }

    /// Builds the next track's `AVPlayerItem` ahead of time. An `AVPlayerItem` starts loading its
    /// asset and buffering media data as soon as it's created — whether or not it's attached to a
    /// player yet — so this one is ready to swap straight in once the current track ends.
    private func prepareNextItem() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex), preparedIndex != nextIndex else { return }
        guard let url = try? client.streamURL(forId: queue[nextIndex].id.raw) else { return }
        preparedItem = AVPlayerItem(url: url)
        preparedIndex = nextIndex
    }

    private func clearPreparedItem() {
        preparedItem = nil
        preparedIndex = nil
    }

    private func handleTimeUpdate(_ time: TimeInterval) {
        currentTime = time
        ticksSincePersist += 1
        if ticksSincePersist >= 10 {
            ticksSincePersist = 0
            // Corrects any drift between the real elapsed time and what Control Center is
            // extrapolating on its own from the last rate/elapsed-time update.
            updateNowPlayingPlaybackState()
            persistState()
        }
        // Retry preparing the next item if it wasn't ready right after loading (e.g. a transient
        // network hiccup) — give it another shot as the current track nears its end.
        if preparedItem == nil, duration > 0, duration - time < 15 {
            prepareNextItem()
        }
    }

    private func updateArtworkURL() {
        guard let track = currentTrack else {
            artworkURL = nil
            return
        }
        let artId = track.coverArt ?? track.albumId?.raw ?? track.id.raw
        artworkURL = try? client.coverArtURL(forId: artId)
    }

    private func configureAudioSessionIfNeeded() {
        guard !didConfigureAudioSession else { return }
        didConfigureAudioSession = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Now Playing / remote control (lock screen, Control Center)

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            isCurrentTrackStarred = false
            updateNowPlayingFeedback()
            return
        }
        isCurrentTrackStarred = track.isStarred
        updateNowPlayingFeedback()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadNowPlayingArtwork()
    }

    /// Updates elapsed time and playback rate together. Control Center doesn't just display
    /// `MPNowPlayingInfoPropertyElapsedPlaybackTime` verbatim — it extrapolates position locally
    /// from that value and `MPNowPlayingInfoPropertyPlaybackRate` as of the last update. Changing
    /// only the rate (e.g. on pause) while leaving a stale elapsed time in place makes it snap
    /// back to whatever position was last recorded there, which is why these two must always be
    /// set together.
    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Keeps the lock screen / Control Center "favorite" toggle's filled/outline state in sync
    /// with `isCurrentTrackStarred`.
    private func updateNowPlayingFeedback() {
        MPRemoteCommandCenter.shared().likeCommand.isActive = isCurrentTrackStarred
    }

    private func loadNowPlayingArtwork() {
        guard let artworkURL else { return }
        Task { [weak self] in
            guard let self, let uiImage = await ImageCache.shared.load(artworkURL) else { return }
            await MainActor.run {
                guard self.artworkURL == artworkURL, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }

        // The lock screen / Control Center "favorite" toggle — same star/unstar call as
        // `PlayerView`'s star button. `MPFeedbackCommand` has no star glyph option; the system
        // renders `likeCommand` as a heart, but it drives the identical underlying action.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "Favorite")
        center.likeCommand.addTarget { [weak self] _ in
            self?.toggleStarred()
            return .success
        }
    }

    // MARK: - Persistence across launches

    private struct PersistedState: Codable {
        let queue: [Child]
        let currentIndex: Int
        let currentTime: TimeInterval
    }

    private static let persistenceKey = "PlayerManager.state"

    private func persistState() {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
            return
        }
        let state = PersistedState(queue: queue, currentIndex: currentIndex, currentTime: currentTime)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    /// Restores the last session's queue, current track, and position — without starting
    /// playback or streaming anything yet. Actual streaming resumes lazily on the first
    /// `resume()`/`togglePlayPause()` call, so this doesn't require server access just to launch
    /// the app or show the mini player.
    private func restorePersistedState() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.queue.indices.contains(state.currentIndex)
        else { return }
        queue = state.queue
        currentIndex = state.currentIndex
        currentTime = state.currentTime
        duration = TimeInterval(state.queue[state.currentIndex].duration ?? 0)
        updateArtworkURL()
        updateNowPlayingInfo()
    }
}
