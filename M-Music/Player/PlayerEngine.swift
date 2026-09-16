import AVFoundation
import AudioToolbox
import Combine
import Foundation

/// Owns a single `AVQueuePlayer` and gives `PlayerManager` true gapless transitions: instead of
/// swapping in a freshly-built `AVPlayerItem` once the current one finishes (a beat of silence
/// while it loads, however small), `preloadForGapless(url:)` inserts the next item into the queue
/// *ahead of time* so AVFoundation itself performs the handoff the instant the current item ends.
///
/// Ported from Shelv's `PlayerEngine` (`ShelvCore/Services/PlayerEngine.swift`).
@MainActor
final class PlayerEngine: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    /// Reflects `AVPlayer`'s actual playback state — unlike `isPlaying`, this only flips to true
    /// once AVFoundation has actually started advancing the current item (not just been asked to).
    @Published private(set) var isActuallyPlaying: Bool = false
    @Published private(set) var isWaiting: Bool = false
    @Published private(set) var isLikelyToKeepUp: Bool = true

    var onTrackFinished: (() -> Void)?
    var onPlaybackFailed: ((Error?) -> Void)?
    var onPlaybackStalled: (() -> Void)?

    /// Overall output volume: the product of the app's own volume (currently always 1) and the
    /// current track's ReplayGain adjustment, clamped to `0...1` (`AVPlayer.volume` can only
    /// attenuate, not boost).
    var volume: Float = 1.0 {
        didSet { applyEffectiveVolume() }
    }
    private var replayGainVolume: Float = 1.0

    private let player: AVQueuePlayer
    private var timeObserverToken: Any?
    private var itemFinishedObserver: NSObjectProtocol?
    private var itemFailureObserver: NSObjectProtocol?
    private var itemStallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var likelyKeepUpObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var playbackToken = UUID()
    private var hasFailed = false
    private var isSeeking = false
    private var gaplessNextItem: AVPlayerItem?
    private var gaplessNextURL: URL?
    private var gaplessPreloaded = false
    private var pendingResumeAfterBuffer = false

    init() {
        let p = AVQueuePlayer()
        p.allowsExternalPlayback = false
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        timeControlObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentStatus = player.timeControlStatus
                self.isWaiting = currentStatus == .waitingToPlayAtSpecifiedRate
                self.isActuallyPlaying = currentStatus == .playing
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeTimeObserver()
            removeItemFinishedObserver()
            itemStatusObservation?.invalidate()
            likelyKeepUpObservation?.invalidate()
            timeControlObservation?.invalidate()
            if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
        }
    }

    func play(url: URL) {
        playbackToken = UUID()
        let token = playbackToken
        currentURL = url
        gaplessPreloaded = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        loadAndPlay(url: url, token: token)
    }

    private func loadAndPlay(url: URL, token: UUID) {
        hasFailed = false
        isActuallyPlaying = false
        gaplessPreloaded = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        pendingResumeAfterBuffer = false
        isSeeking = false

        let item = makePlayerItem(url: url)
        player.pause()
        player.removeAllItems()
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        applyEffectiveVolume()
        player.insert(item, after: nil)
        player.play()

        isPlaying = true
        setupTimeObserver(for: token)
        setupItemFinishedObserverForItem(item, token: token)
        setupFailureObservation(item: item, url: url, token: token)
    }

    private func setupFailureObservation(item: AVPlayerItem, url: URL, token: UUID) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self else { return }
            if observedItem.status == .failed {
                Task { @MainActor in self.notifyFailure(for: url, token: token) }
            }
        }

        likelyKeepUpObservation?.invalidate()
        likelyKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] observedItem, _ in
            let likely = observedItem.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playbackToken == token else { return }
                self.isLikelyToKeepUp = likely
                if likely && self.pendingResumeAfterBuffer {
                    self.pendingResumeAfterBuffer = false
                    self.player.play()
                    self.isPlaying = true
                }
            }
        }

        if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.notifyFailure(for: url, token: token) }
        }

        if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
        itemStallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.playbackToken == token,
                  let currentItem = self.player.currentItem
            else { return }
            self.onPlaybackStalled?()
            if currentItem.status == .failed {
                Task { @MainActor in self.notifyFailure(for: url, token: token) }
            }
        }
    }

    private func notifyFailure(for url: URL, token: UUID) {
        guard playbackToken == token, currentURL == url, !hasFailed else { return }
        hasFailed = true
        isPlaying = false
        isActuallyPlaying = false
        onPlaybackFailed?(player.currentItem?.error)
    }

    /// Builds `url`'s `AVPlayerItem` and inserts it into the queue right after the currently
    /// playing item — it starts buffering immediately, and `AVQueuePlayer` advances into it on its
    /// own once the current item ends, with no gap.
    func preloadForGapless(url: URL) {
        guard let currentItem = player.currentItem else { return }
        let nextItem = makePlayerItem(url: url)
        gaplessNextItem = nextItem
        gaplessNextURL = url
        player.insert(nextItem, after: currentItem)
        gaplessPreloaded = true
    }

    private func performGaplessSwap() {
        removeItemFinishedObserver()
        hasFailed = false
        gaplessPreloaded = false
        pendingResumeAfterBuffer = false
        currentTime = 0
        isPlaying = true
        isSeeking = false

        let swappedURL = gaplessNextURL
        let swappedItem = gaplessNextItem
        gaplessNextURL = nil
        gaplessNextItem = nil

        if let url = swappedURL {
            currentURL = url
            player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        }

        if let item = swappedItem {
            setupItemFinishedObserverForItem(item, token: playbackToken)
            if let url = swappedURL {
                let token = playbackToken
                setupFailureObservation(item: item, url: url, token: token)
                if item.status == .failed {
                    Task { @MainActor [weak self] in self?.notifyFailure(for: url, token: token) }
                }
            }
        } else {
            setupItemFinishedObserver()
        }

        // `AVQueuePlayer` is *supposed* to keep the transport running on its own once it advances
        // into the next queued item, but doesn't always reliably do so right at the boundary —
        // observed as: `isPlaying` says true, but the real player sits at `rate == 0` forever,
        // and nothing else ever calls `.play()` again to nudge it. An explicit call here is a
        // no-op if the queue player already continued on its own, and fixes it if it didn't —
        // exactly mirroring what `loadAndPlay`/`resume()` already do for every other transition.
        player.play()
    }

    func pause() {
        // A user-initiated pause clears any pending buffer-triggered resume — otherwise the
        // player could spring back to life the moment it finishes buffering, against the user's
        // own choice.
        pendingResumeAfterBuffer = false
        player.pause()
        isPlaying = false
        isActuallyPlaying = false
    }

    func resume() {
        pendingResumeAfterBuffer = false
        player.play()
        isPlaying = true
    }

    func seek(to seconds: TimeInterval, pauseUntilBuffered: Bool = false, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        isSeeking = true
        currentTime = seconds
        if pauseUntilBuffered {
            // Pause explicitly while AVPlayer waits for the seek target to buffer, instead of
            // letting it silently advance its internal clock with no audio — the
            // `isPlaybackLikelyToKeepUp` observation above resumes automatically once buffered.
            player.pause()
            isPlaying = false
            pendingResumeAfterBuffer = true
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.isSeeking = false
                completion?(finished)
            }
        }
    }

    func setReplayGainVolume(_ volume: Float) {
        replayGainVolume = max(0, min(volume, 1.0))
        applyEffectiveVolume()
    }

    private func applyEffectiveVolume() {
        player.volume = max(0, min(volume * replayGainVolume, 1))
    }

    struct AudioFormatInfo: Equatable {
        let codec: String
        /// kbps — set for a lossy codec, `nil` for a lossless one (see `bitDepth`/`sampleRateHz`
        /// instead, since a lossless codec doesn't have a single fixed bitrate worth reporting).
        let bitrateKbps: Int?
        let bitDepth: Int?
        let sampleRateHz: Double?
    }

    private static let losslessCodecLabels: Set<String> = ["ALAC", "FLAC", "WAV"]

    /// The URL currently loaded (or being swapped into) the player — so `PlayerManager` can pass
    /// it back into `currentAudioFormat(matching:)` right after a gapless swap, when it has no
    /// other way to know exactly what just became current.
    var currentPlaybackURL: URL? { currentURL }

    /// Reads the *real* codec (and bitrate, or bit depth/sample rate for a lossless codec) off the
    /// currently loaded item's audio track — the only reliable source of truth, since transcoding
    /// can silently change the codec the server actually sends regardless of what the source
    /// file's extension implies. `url` must be whatever the caller believes is currently playing
    /// (`play(url:)`'s argument, or `currentPlaybackURL` right after a gapless swap) — guards
    /// against the current item having already changed again by the time the async metadata
    /// loads finish, the same way `notifyFailure(for:token:)` guards against a stale failure.
    /// Returns `nil` if nothing's loaded, the format metadata isn't available (yet), or that guard
    /// trips.
    func currentAudioFormat(matching url: URL) async -> AudioFormatInfo? {
        guard currentURL == url, let asset = player.currentItem?.asset else { return nil }
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        guard let formatDescriptions = try? await track.load(.formatDescriptions), let fd = formatDescriptions.first else {
            return nil
        }
        guard currentURL == url else { return nil }
        let codec = Self.codecLabel(forFormatID: CMFormatDescriptionGetMediaSubType(fd))
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        if Self.losslessCodecLabels.contains(codec), let asbd, asbd.mBitsPerChannel > 0 {
            return AudioFormatInfo(codec: codec, bitrateKbps: nil, bitDepth: Int(asbd.mBitsPerChannel), sampleRateHz: asbd.mSampleRate)
        }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        guard currentURL == url else { return nil }
        let kbps = rate > 0 ? Int((rate / 1000).rounded()) : nil
        return AudioFormatInfo(codec: codec, bitrateKbps: kbps, bitDepth: nil, sampleRateHz: asbd?.mSampleRate)
    }

    private static func codecLabel(forFormatID id: FourCharCode) -> String {
        switch id {
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatOpus: return "OPUS"
        case kAudioFormatLinearPCM: return "WAV"
        case kAudioFormatAC3: return "AC3"
        default:
            let bytes = [UInt8((id >> 24) & 0xff), UInt8((id >> 16) & 0xff),
                         UInt8((id >> 8) & 0xff), UInt8(id & 0xff)]
            let s = (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "?" : s.uppercased()
        }
    }

    func stop() {
        playbackToken = UUID()
        removeTimeObserver()
        removeItemFinishedObserver()
        removeFailureObservation()
        currentURL = nil
        hasFailed = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        pendingResumeAfterBuffer = false
        player.pause()
        player.removeAllItems()
        isPlaying = false
        isActuallyPlaying = false
        isWaiting = false
        isLikelyToKeepUp = true
        gaplessPreloaded = false
        currentTime = 0
        duration = 0
    }

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let asset = url.isFileURL
            ? AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            : AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func removeFailureObservation() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        likelyKeepUpObservation?.invalidate()
        likelyKeepUpObservation = nil
        if let obs = itemFailureObserver {
            NotificationCenter.default.removeObserver(obs)
            itemFailureObserver = nil
        }
        if let obs = itemStallObserver {
            NotificationCenter.default.removeObserver(obs)
            itemStallObserver = nil
        }
    }

    private func setupTimeObserver(for token: UUID) {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.playbackToken == token else { return }
                self.refreshDuration()
                guard !self.isSeeking else { return }
                self.currentTime = time.seconds
            }
        }
    }

    private func removeTimeObserver() {
        guard let token = timeObserverToken else { return }
        player.removeTimeObserver(token)
        timeObserverToken = nil
    }

    private func setupItemFinishedObserver() {
        guard let item = player.currentItem else { return }
        setupItemFinishedObserverForItem(item, token: playbackToken)
    }

    private func setupItemFinishedObserverForItem(_ item: AVPlayerItem, token: UUID) {
        removeItemFinishedObserver()
        itemFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.playbackToken == token else { return }
                if self.gaplessPreloaded {
                    self.performGaplessSwap()
                    self.onTrackFinished?()
                } else {
                    self.isPlaying = false
                    self.isActuallyPlaying = false
                    self.onTrackFinished?()
                }
            }
        }
    }

    private func removeItemFinishedObserver() {
        guard let obs = itemFinishedObserver else { return }
        NotificationCenter.default.removeObserver(obs)
        itemFinishedObserver = nil
    }

    private func refreshDuration() {
        guard let item = player.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 {
            duration = d
        }
    }
}
