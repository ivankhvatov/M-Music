import AVFoundation
import Foundation
import Combine
import MediaPlayer
import UIKit

/// Owns playback of the current queue via `PlayerEngine`, resolving each track through a
/// three-tier lookup — an already-downloaded file (`LocalDownloadIndex`), a prefetched stream
/// cache file (`StreamCacheService`), or a live `SubsonicClient.streamURL(forId:)` — the same way
/// across the app (mini player, full-screen player, and whatever starts playback).
///
/// Supports background playback (a `.playback` audio session plus the `audio` background mode,
/// with lock screen / Control Center integration via `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`), true gapless transitions between tracks for the natural
/// end-of-queue-track case (`PlayerEngine.preloadForGapless`, backed by an `AVQueuePlayer` that
/// performs the handoff itself rather than a fresh item being swapped in after the fact), and
/// persists the current queue, track, and position across launches.
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
    private let engine = PlayerEngine()
    private var subscriptions: Set<AnyCancellable> = []
    private var backgroundObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var didConfigureAudioSession = false
    /// Whether playback was active right before the interruption currently in progress (a phone
    /// call, Siri, another app taking audio focus, ...) — so `.ended` only resumes what we were
    /// actually doing, not something the user had already paused themselves before it started.
    private var wasPlayingBeforeInterruption = false
    /// Whether `engine.play(url:)` has ever been called for the current `PlayerManager` instance
    /// — mirrors the old "is there an `AVPlayer` yet" check: after a cold launch, session state
    /// is restored (queue/position) without actually streaming anything until playback resumes.
    private var hasLoadedItem = false

    /// The queue index `engine.preloadForGapless(url:)` was last called for, so the natural
    /// end-of-track callback can tell whether `PlayerEngine`'s `AVQueuePlayer` already performed
    /// the gapless handoff to it internally (nothing further to load) or whether it needs a fresh
    /// `engine.play(url:)` call (nothing was ready in time, or the queue changed since).
    private var gaplessPreloadedIndex: Int?

    /// The song id `GaplessCacheService.enqueue` was last asked to cache, while that download is
    /// still in flight — cleared once it lands (or is superseded). Lets `prepareNextItem()` cancel
    /// a now-stale download if the "next" track changes again before it finishes.
    private var gaplessCachingSongId: String?

    /// Throttles how often playback position is written to disk — every time-observer tick would
    /// mean a disk write twice a second for as long as something is playing.
    private var ticksSincePersist = 0

    private let starStore = StarStore.shared

    /// Bounds how many times `recoverFromPlaybackFailure(error:)` will retry the *same* song
    /// before giving up on it — see that method. Reset whenever the failing track differs from
    /// `retryingTrackId`, so each song gets its own fresh budget.
    private var streamFailureRetryPolicy = RemoteStreamFailureRetryPolicy()
    private var retryingTrackId: String?

    init(client: SubsonicClient = .shared) {
        self.client = client
        restorePersistedState()
        configureRemoteCommandCenter()
        subscribeToEngine()
        // Eagerly, so an already-cached track (from an earlier session) resolves correctly the
        // very first time it's tapped, rather than only after some other download happens to run
        // first and trigger this as a side effect — see `GaplessCacheService.preload()`.
        Task { await GaplessCacheService.shared.preload() }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistState() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
    }

    private func subscribeToEngine() {
        engine.$currentTime
            .sink { [weak self] time in self?.handleTimeUpdate(time) }
            .store(in: &subscriptions)
        engine.$duration
            .sink { [weak self] duration in
                guard let self, duration > 0 else { return }
                self.duration = duration
            }
            .store(in: &subscriptions)
        engine.$isPlaying
            .sink { [weak self] isPlaying in self?.isPlaying = isPlaying }
            .store(in: &subscriptions)
        // Keeps `isCurrentTrackStarred` (and the lock screen's "favorite" toggle) in sync with
        // every star/unstar change — including ones made elsewhere, like `AlbumView` or
        // `SongsListView` starring a track that happens to be the one currently playing.
        // Reads the overrides straight from this sink's payload rather than re-reading
        // `starStore.overrides` afterward: `@Published` publishes from `willSet`, so a
        // synchronous re-read from inside this closure would still see the pre-update
        // dictionary, flipping `isCurrentTrackStarred` to the opposite of what was just set.
        starStore.$overrides
            .sink { [weak self] overrides in
                guard let self, let track = self.currentTrack else { return }
                self.isCurrentTrackStarred = overrides[track.id.raw] ?? track.isStarred
                self.updateNowPlayingFeedback()
            }
            .store(in: &subscriptions)
        engine.onTrackFinished = { [weak self] in
            Task { @MainActor in self?.handleTrackFinishedNaturally() }
        }
        engine.onPlaybackFailed = { [weak self] error in
            Task { @MainActor in self?.recoverFromPlaybackFailure(error: error) }
        }
        // Once the upcoming track's gapless-cache download lands, preload it — this is what
        // actually delivers a gapless transition for a cached track, since `prepareNextItem()`
        // itself only kicks off the download (see its doc comment).
        GaplessCacheStatus.shared.$cachedEntries
            .sink { [weak self] entries in
                guard let self, let currentIndex else { return }
                let nextIndex = currentIndex + 1
                guard queue.indices.contains(nextIndex) else { return }
                let nextTrack = queue[nextIndex]
                guard let entry = entries[nextTrack.id.raw] else { return }
                if gaplessCachingSongId == nextTrack.id.raw {
                    gaplessCachingSongId = nil
                }
                guard gaplessPreloadedIndex == nil, isGaplessCacheEntry(entry, validFor: nextTrack) else { return }
                engine.preloadForGapless(url: entry.url)
                gaplessPreloadedIndex = nextIndex
            }
            .store(in: &subscriptions)
    }

    /// The system pauses output itself for the duration of an interruption (a phone call, Siri,
    /// another app taking audio focus, ...) — without this, nothing here ever finds out, so
    /// `isPlaying`/the lock screen keep claiming playback is active while it's actually silent,
    /// and nothing resumes it once the interruption is over.
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended:
            defer { wasPlayingBeforeInterruption = false }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard wasPlayingBeforeInterruption,
                  AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            resume()
        @unknown default:
            break
        }
    }

    /// Starts streaming the track at `index` in `newQueue`. Tracks before it become playback
    /// history (reachable via `previous()`); tracks after it play next — e.g. pass an album's
    /// full track list and the tapped track's index to queue the rest of the album.
    func play(queue newQueue: [Child], startAt index: Int) {
        guard newQueue.indices.contains(index) else { return }
        queue = newQueue
        currentIndex = index
        clearGaplessPreload()
        loadCurrentItem(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func next() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            finishQueue()
            return
        }
        self.currentIndex = nextIndex
        clearGaplessPreload()
        loadCurrentItem(autoplay: true)
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
            clearGaplessPreload()
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
        // Whatever was preloaded (if anything) was built for whatever used to sit at
        // `currentIndex + 1`, which has now shifted one slot later — rebuild it against the
        // newly-inserted track.
        clearGaplessPreload()
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
        if gaplessPreloadedIndex == nil {
            prepareNextItem()
        }
        persistState()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        engine.seek(to: clamped)
        updateNowPlayingPlaybackState()
        persistState()
    }

    /// Stars/unstars the current track via the shared `StarStore` — used by `PlayerView`'s star
    /// button and the lock screen / Control Center "favorite" toggle, so both stay in sync and do
    /// the same thing. `isCurrentTrackStarred` picks up the result via the `starStore.$overrides`
    /// subscription in `subscribeToEngine()`, same as any other star change from `AlbumView` or
    /// `SongsListView`.
    func toggleStarred() {
        guard let track = currentTrack else { return }
        starStore.toggleStarred(track)
    }

    // MARK: - Playback control

    private func resume() {
        guard currentTrack != nil else { return }
        guard hasLoadedItem else {
            // Lazily restored from a previous session: nothing's been streamed yet, so build the
            // item now and pick up from the restored `currentTime`.
            loadCurrentItem(autoplay: true, startTime: currentTime)
            return
        }
        engine.resume()
        updateNowPlayingPlaybackState()
        persistState()
    }

    private func pause() {
        guard hasLoadedItem, isPlaying else { return }
        engine.pause()
        updateNowPlayingPlaybackState()
        persistState()
    }

    /// Reached the end of the queue: rewind to the first track and stop, like Apple Music.
    private func finishQueue() {
        clearGaplessPreload()
        if queue.isEmpty {
            currentIndex = nil
            engine.stop()
            hasLoadedItem = false
        } else {
            currentIndex = 0
            loadCurrentItem(autoplay: false)
        }
        persistState()
    }

    // MARK: - Item loading

    private func loadCurrentItem(autoplay: Bool, startTime: TimeInterval = 0) {
        configureAudioSessionIfNeeded()
        guard let track = currentTrack, let url = try? streamURL(for: track) else {
            isPlaying = false
            return
        }
        hasLoadedItem = true
        engine.play(url: url)
        if !autoplay {
            engine.pause()
        }
        engine.setReplayGainVolume(replayGainVolume(for: track))

        duration = TimeInterval(track.duration ?? 0)
        currentTime = startTime
        if startTime > 0 {
            engine.seek(to: startTime)
        }

        updateArtworkURL()
        updateNowPlayingInfo()
        prepareNextItem()
        updateNowPlayingPlaybackState()
        persistState()
    }

    /// The natural end of the current track — as opposed to an explicit `next()`/`previous()`
    /// tap. If `prepareNextItem()` had already preloaded this next track into `PlayerEngine`'s
    /// `AVQueuePlayer`, it has already performed the seamless handoff internally by the time this
    /// runs (that's what makes the transition gapless) and there's nothing left to load — just
    /// bookkeeping. Otherwise (nothing was ready in time), fall back to a fresh load.
    private func handleTrackFinishedNaturally() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            finishQueue()
            return
        }
        self.currentIndex = nextIndex

        if gaplessPreloadedIndex == nextIndex {
            gaplessPreloadedIndex = nil
            let track = queue[nextIndex]
            duration = TimeInterval(track.duration ?? 0)
            currentTime = 0
            engine.setReplayGainVolume(replayGainVolume(for: track))
            // The gapless-swap path never re-resolves the URL (it was already handed to the
            // engine back when this was preloaded), so `streamURL(for:)`'s own touch doesn't run
            // for this case — do it here instead, for whichever track just became current.
            if let entry = GaplessCacheStatus.shared.entry(for: track.id.raw), isGaplessCacheEntry(entry, validFor: track) {
                Task { await GaplessCacheService.shared.touch(songId: track.id.raw) }
            }
            updateArtworkURL()
            updateNowPlayingInfo()
            prepareNextItem()
            updateNowPlayingPlaybackState()
            persistState()
        } else {
            clearGaplessPreload()
            loadCurrentItem(autoplay: true)
        }
    }

    /// A stream failed mid-playback (e.g. a transient network hiccup, or the server closing an
    /// idle connection partway through — this can happen well into a live-transcoded track, not
    /// just at a transition) — without this, nothing else happens: `isPlaying` stays true with no
    /// audio and no progress, forever.
    ///
    /// Bounded via `streamFailureRetryPolicy` (ported from Shelv) rather than always retrying: if
    /// the failure isn't a transient network error, or this song has already used its small retry
    /// budget, skip to the next track instead — otherwise a persistent, recurring cause (e.g. a
    /// fixed-duration connection limit somewhere between here and the server) would retry forever,
    /// hitting the exact same failure every time.
    ///
    /// When it does retry, a live-transcoded track with no local copy gets `startTime: 0` instead
    /// of the current position: the reconnect is necessarily a **fresh** transcode (Navidrome has
    /// no "resume this transcode at time X"), and seeking that into a nonzero position is exactly
    /// what produced the reported glitch/restart — an honest restart from 0 is broken but not
    /// corrupted. A raw stream, a download, or a gapless-cache hit can still seek back to
    /// `currentTime` correctly, since a real file (or a plain static stream) genuinely supports
    /// resuming via Range.
    private func recoverFromPlaybackFailure(error: Error?) {
        guard let track = currentTrack else { return }
        if track.id.raw != retryingTrackId {
            streamFailureRetryPolicy.reset()
            retryingTrackId = track.id.raw
        }
        guard streamFailureRetryPolicy.shouldRetry(for: error) else {
            next()
            return
        }
        clearGaplessPreload()
        let hasLocalCopy = LocalDownloadIndex.shared.url(songId: track.id.raw) != nil
            || GaplessCacheStatus.shared.entry(for: track.id.raw).map { isGaplessCacheEntry($0, validFor: track) } == true
        let startTime = (!hasLocalCopy && shouldTranscode(track)) ? 0 : currentTime
        loadCurrentItem(autoplay: isPlaying, startTime: startTime)
    }

    /// Codecs that store audio without loss — the only ones worth transcoding under
    /// `TranscodeFileScope.losslessOnly`, since re-encoding an already-lossy file only loses more
    /// quality without the bandwidth win that matters for lossless sources.
    private static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"]

    private func shouldTranscode(_ track: Child) -> Bool {
        guard TranscodingSettings.isEnabled else { return false }
        if TranscodingSettings.fileScope == .losslessOnly {
            guard let suffix = track.suffix?.lowercased(), Self.losslessCodecs.contains(suffix) else { return false }
        }
        switch TranscodingSettings.network {
        case .both: return true
        case .wifi: return NetworkMonitor.shared.isOnWiFi
        case .cellular: return NetworkMonitor.shared.isOnCellular
        }
    }

    /// The live network URL for `track` per the current streaming transcoding settings — source
    /// quality if transcoding is off, doesn't apply to this file scope, or the current network
    /// doesn't match. Used both as `streamURL(for:)`'s final fallback and as the URL
    /// `StreamCacheService` prefetches ahead of the track boundary.
    private func liveStreamURL(for track: Child) throws -> URL {
        guard shouldTranscode(track) else {
            return try client.streamURL(forId: track.id.raw)
        }
        return try client.streamURL(
            forId: track.id.raw, maxBitRate: TranscodingSettings.bitrate.rawValue, format: TranscodingSettings.format.rawValue
        )
    }

    /// A playable URL for `track`, checked in order: an already-downloaded file, a
    /// `GaplessCacheService` hit (only while the feature is enabled), a prefetched
    /// `StreamCacheService` file, then the live network stream (transcoded per
    /// `TranscodingSettings`).
    private func streamURL(for track: Child) throws -> URL {
        if let localURL = LocalDownloadIndex.shared.url(songId: track.id.raw) {
            return localURL
        }
        if GaplessCacheSettings.isEnabled,
           let entry = GaplessCacheStatus.shared.entry(for: track.id.raw), isGaplessCacheEntry(entry, validFor: track) {
            Task { await GaplessCacheService.shared.touch(songId: track.id.raw) }
            return entry.url
        }
        if let cachedURL = StreamCacheStatus.shared.url(for: track.id.raw) {
            return cachedURL
        }
        return try liveStreamURL(for: track)
    }

    /// Whether a `GaplessCacheStatus` entry still matches what `track` would currently resolve
    /// to — a settings change (streaming format/bitrate, or transcoding turned off/on) makes an
    /// old entry a stale miss instead of serving the wrong quality.
    private func isGaplessCacheEntry(_ entry: GaplessCacheStatus.Entry, validFor track: Child) -> Bool {
        if shouldTranscode(track) {
            return entry.format == TranscodingSettings.format.rawValue && entry.bitrate == TranscodingSettings.bitrate.rawValue
        }
        return entry.format == "raw"
    }

    /// The player-wide volume for `track`'s ReplayGain adjustment. Applied via
    /// `PlayerEngine.setReplayGainVolume` rather than a per-item `AVAudioMix`: an audio mix needs
    /// the item's audio track loaded asynchronously before it takes effect, and in practice
    /// that's too easy to lose the race against playback starting — even building the item a
    /// whole track ahead of time (`prepareNextItem`) wasn't reliably enough lead time. The
    /// engine's volume takes effect synchronously and instantly, at the cost of only being able
    /// to attenuate: values above 1 are clamped to no change, since this can't express a boost
    /// the way a mix could.
    private func replayGainVolume(for track: Child) -> Float {
        Float(min(ReplayGainSettings.linearGain(for: track), 1))
    }

    /// Builds the next track's URL ahead of time and hands it to `PlayerEngine` to preload into
    /// its `AVQueuePlayer` — that's what makes the natural transition into it gapless. Also kicks
    /// off a `StreamCacheService` prefetch of the live URL (skipped for an already-downloaded
    /// track) so a later retry of this same call — `handleTimeUpdate` retries it as the current
    /// track nears its end — has a better chance of finding a local copy already sitting in the
    /// cache instead of a live network URL, more resilient to a hiccup right at the boundary.
    ///
    /// Deliberately does *nothing* when the next track has no local copy and would be streamed
    /// through the server's live transcoder: unlike a static file, a transcoded stream is
    /// generated on the fly for one request and can't be meaningfully paused mid-download and
    /// resumed later. Preloading it this far ahead of when it's actually needed leaves that
    /// connection sitting idle for the rest of the current track; by the time `AVQueuePlayer`
    /// finally needs it, the connection (or the server's encoder process) has often gone stale,
    /// and reconnecting to a live transcode either restarts it from position 0 or fails outright
    /// — audible as a glitch, a restart, or a dropped track. `handleTrackFinishedNaturally()`'s
    /// fallback opens a fresh connection at the exact moment it's needed instead: a brief reload
    /// rather than a seamless handoff, but reliable. A downloaded track (even one transcoded at
    /// download time) is unaffected — it's just a file on disk by playback time, so it's caught by
    /// the local-copy check below and stays fully gapless.
    private func prepareNextItem() {
        guard let currentIndex else { return }
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex), gaplessPreloadedIndex != nextIndex else { return }
        let nextTrack = queue[nextIndex]

        if GaplessCacheSettings.isEnabled {
            prepareNextItemViaGaplessCache(nextTrack)
            return
        }

        let localURL = LocalDownloadIndex.shared.url(songId: nextTrack.id.raw)
            ?? StreamCacheStatus.shared.url(for: nextTrack.id.raw)
        guard localURL != nil || !shouldTranscode(nextTrack) else { return }

        guard let url = try? streamURL(for: nextTrack) else { return }
        engine.preloadForGapless(url: url)
        gaplessPreloadedIndex = nextIndex

        if localURL == nil, let liveURL = try? liveStreamURL(for: nextTrack) {
            Task {
                await StreamCacheService.shared.prefetch(
                    songId: nextTrack.id.raw, url: liveURL, codec: nextTrack.suffix ?? "", bitrate: 0
                )
            }
        }

        // Only the current and upcoming track are worth keeping cached — without this, every
        // track prefetched over the course of a long listening session would sit in the cache
        // forever.
        let keepIds = Set([queue[currentIndex].id.raw, nextTrack.id.raw])
        Task { await StreamCacheService.shared.trim(keeping: keepIds) }
    }

    /// The `GaplessCacheSettings.isEnabled` path: caches the upcoming track — raw or transcoded —
    /// to a real file ahead of the boundary, superseding `StreamCacheService`'s lighter, raw-only
    /// prefetch. Only kicks off the download here; the `GaplessCacheStatus.$cachedEntries`
    /// subscription in `subscribeToEngine()` is what actually calls `engine.preloadForGapless`
    /// once it lands, since there's no safe URL to preload until then.
    private func prepareNextItemViaGaplessCache(_ nextTrack: Child) {
        if let downloadURL = LocalDownloadIndex.shared.url(songId: nextTrack.id.raw) {
            engine.preloadForGapless(url: downloadURL)
            gaplessPreloadedIndex = currentIndex.map { $0 + 1 }
            return
        }
        if let entry = GaplessCacheStatus.shared.entry(for: nextTrack.id.raw), isGaplessCacheEntry(entry, validFor: nextTrack) {
            engine.preloadForGapless(url: entry.url)
            gaplessPreloadedIndex = currentIndex.map { $0 + 1 }
            return
        }

        guard gaplessCachingSongId != nextTrack.id.raw else { return }
        if let stale = gaplessCachingSongId {
            Task { await GaplessCacheService.shared.cancel(songId: stale) }
        }
        guard let url = try? liveStreamURL(for: nextTrack) else {
            gaplessCachingSongId = nil
            return
        }
        let isTranscode = shouldTranscode(nextTrack)
        let format = isTranscode ? TranscodingSettings.format.rawValue : "raw"
        let bitrate = isTranscode ? TranscodingSettings.bitrate.rawValue : 0
        let fallbackExtension = isTranscode ? TranscodingSettings.format.rawValue : (nextTrack.suffix ?? "mp3")
        gaplessCachingSongId = nextTrack.id.raw
        Task {
            await GaplessCacheService.shared.enqueue(
                songId: nextTrack.id.raw, url: url, format: format, bitrate: bitrate, fallbackExtension: fallbackExtension
            )
        }
    }

    private func clearGaplessPreload() {
        gaplessPreloadedIndex = nil
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
        if gaplessPreloadedIndex == nil, duration > 0, duration - time < 15 {
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

    /// Recomputes `isCurrentTrackStarred` from `StarStore` for whichever track is current right
    /// now — called on every track change and on every store-wide star/unstar change, so this
    /// stays correct however the current track's starred state got updated.
    private func syncCurrentTrackStarredState() {
        guard let track = currentTrack else {
            isCurrentTrackStarred = false
            updateNowPlayingFeedback()
            return
        }
        isCurrentTrackStarred = starStore.isStarred(track)
        updateNowPlayingFeedback()
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            syncCurrentTrackStarredState()
            return
        }
        syncCurrentTrackStarredState()
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
