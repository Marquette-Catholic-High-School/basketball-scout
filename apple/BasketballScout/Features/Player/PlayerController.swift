import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// What the player needs to know about the game's film. A change reloads the player item.
nonisolated struct PlayerFilmInputs: Hashable, Sendable {
    /// The film itself: another value means another film (start again at 0:00).
    nonisolated struct Film: Hashable, Sendable {
        var gameID: String
        var fileName: String?
        var size: Int?
        var link: String?
    }

    var film: Film
    /// `Game.has_video`: the original is stored on the server.
    var hasOriginal: Bool
    /// `Game.has_annotated_video`: the GPU's annotated copy exists.
    var hasAnnotated: Bool
    /// `GameContext.filmRevision`: grows when the film must be loaded again from the same URL (09 R12).
    var revision: Int

    init(game: Game, revision: Int) {
        film = Film(gameID: game.id, fileName: game.videoFilename, size: game.videoSize, link: game.videoURL)
        hasOriginal = game.hasVideo
        hasAnnotated = game.hasAnnotatedVideo
        self.revision = revision
    }

    /// Something can be played (03 §4 `playable`).
    var isPlayable: Bool { hasOriginal || hasAnnotated }
}

/// The game page's film player (04 §4, §6.2; 09 R11–R13): one `AVPlayer`, its item built through the
/// session's `VideoAssetFactory` (authenticated byte ranges), the copy shown (annotated / original) with
/// the web's fallbacks, speed, stepping, and the shared `PlaybackCoordinator` kept in sync (`currentTime`
/// ten times a second while playing, `duration`, `isPlaying`, `rate`; seeks asked for through
/// `pendingSeek` are applied here).
///
/// One per game page (`context.playerController`), so the position survives the page moving the player
/// around. It observes the player only while `run()` is running (the view is visible and the app
/// active, 09 R29) and pauses when the last view stops.
@Observable
final class PlayerController {
    /// Where the player item stands.
    enum Phase: Equatable {
        /// Nothing to play (no film, or signed out).
        case idle
        /// The item is opening.
        case loading
        case ready
        /// The item failed (see `notice` / `loadError`).
        case failed
    }

    let player: AVPlayer
    let playback: PlaybackCoordinator

    private(set) var phase: Phase = .idle
    /// The copy loaded (or loading).
    private(set) var variant: VideoVariant?
    /// The original can be shown: stored on the server and not failed here.
    private(set) var hasOriginal = false
    /// The annotated copy can be shown: it exists and has not failed here.
    private(set) var hasAnnotated = false
    /// Why another copy is shown, or that nothing plays (info / warning).
    private(set) var notice: NoticeText?
    /// A film request failed (network, server): shown with "Try again" when retryable.
    private(set) var loadError: (any PresentableError)?
    /// The film's size in pixels once known (captions are placed on the picture).
    private(set) var presentationSize: CGSize = .zero
    /// The calibration sheet is open: paused, no captions, no reloads until it closes (04 §6.3).
    private(set) var isCalibrating = false
    /// The "Captions" checkbox (on by default, player.js:73).
    var captionsOn = true
    /// The pointer is over the film (Mac, iPad pointer): the system controls show, captions move up.
    var isPointerOverVideo = false

    @ObservationIgnored private let report: (any Error, APIClient?) -> (any PresentableError)?
    @ObservationIgnored private var inputs: PlayerFilmInputs?
    @ObservationIgnored private var factory: VideoAssetFactory?
    @ObservationIgnored private var loaded: Loaded?
    @ObservationIgnored private var coachChose = false
    @ObservationIgnored private var annotatedListed = false
    @ObservationIgnored private var unavailable: Set<VideoVariant> = []
    @ObservationIgnored private var restore: Restore?
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var activeRuns = 0
    @ObservationIgnored private var seeksInFlight = 0
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var reloadAfterCalibration = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    /// How often the shared `currentTime` follows the film while it plays.
    static let timeUpdateInterval = CMTime(value: 1, timescale: 10)
    /// When the last view stops, the player pauses after this grace (a view that only moved starts again
    /// before it ends).
    static let stopGrace: Duration = .milliseconds(400)

    /// - Parameters:
    ///   - playback: the page's shared playback state.
    ///   - report: passes an error through the lockout gate and returns what to show
    ///     (`ServerSession.report(_:from:)`).
    init(playback: PlaybackCoordinator, report: @escaping (any Error, APIClient?) -> (any PresentableError)?) {
        self.playback = playback
        self.report = report
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        player.defaultRate = Float(playback.rate)
        self.player = player
    }

    // MARK: - Facts

    var isReady: Bool { phase == .ready }

    /// The one-key shortcuts and the step / event buttons work (07 §9: not without a loaded film).
    var acceptsCommands: Bool { phase == .ready && !isCalibrating }

    /// The captions overlay is drawn: "Captions" on, not calibrating, a film loaded or loading (player.js:379).
    var showsCaptions: Bool { captionsOn && !isCalibrating && phase != .idle }

    /// The system controls are probably on screen (paused, or the pointer is over the film): the event
    /// caption moves above them (player.js:392).
    var controlsLikelyVisible: Bool { !playback.isPlaying || isPointerOverVideo }

    /// The player's position in seconds: the target of a seek still running (so repeated steps and event
    /// jumps add up), else the player's time while ready, else the time to restore while loading.
    var currentSeconds: Double {
        if let seekTarget { return seekTarget }
        if phase == .ready, player.currentItem != nil {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { return seconds }
        }
        if let restore { return restore.time }
        return playback.currentTime
    }

    // MARK: - Inputs and lifecycle

    /// The game's film changed (or the session's film loader): reloads as the web does on a page refresh.
    func update(_ inputs: PlayerFilmInputs?, factory: VideoAssetFactory?) {
        self.inputs = inputs
        self.factory = factory
        apply()
    }

    /// Observes the player while the calling task runs (the view is on screen and the app active; call it
    /// from `.taskWhileActive`). Loads the film on the first run. When the last run ends the player pauses.
    func run() async {
        stopTask?.cancel()
        stopTask = nil
        activeRuns += 1
        if timeObserver == nil { startObserving() }
        apply()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        activeRuns -= 1
        guard activeRuns == 0 else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stopGrace)
            guard !Task.isCancelled, let self, self.activeRuns == 0 else { return }
            self.stopObserving()
            self.player.pause()
        }
    }

    // MARK: - Commands

    func togglePlay() {
        guard acceptsCommands else { return }
        if player.timeControlStatus == .paused {
            play()
        } else {
            player.pause()
        }
    }

    func play() {
        guard phase == .ready else { return }
        // A film at its end starts again, as a browser's play() does.
        if let duration = playback.duration, currentSeconds >= duration - 0.05 { seek(to: 0) }
        player.defaultRate = Float(playback.rate)
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// ←/→ (5 s) and Shift+←/→ (1 s) (player.js:252-254, 284-288).
    func step(by seconds: Double) {
        guard acceptsCommands else { return }
        seek(to: currentSeconds + seconds)
    }

    /// The speed menu (0.25×–2×). Playback continues at the new speed; `play` uses it later.
    func setRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        playback.rate = rate
        player.defaultRate = Float(rate)
        if player.rate != 0 { player.rate = Float(rate) }
    }

    /// "Annotated" / "Original": the coach's pick, kept when the analysis later adds an annotated copy.
    /// The time and the playing state carry over (player.js:155-158, 186-213).
    func chooseVariant(_ requested: VideoVariant) {
        coachChose = true
        load(requested, keepTime: true, reload: false)
    }

    /// "Try again" after a failed film request: the same copy, from the same time.
    func retry() {
        loadError = nil
        if let variant {
            load(variant, keepTime: true, reload: true)
        } else {
            apply()
        }
    }

    /// "Event ▶" / `]`: to the next marker, 3 s early (player.js:258-262).
    func goToNextEvent(in markers: [TimelineEvent]) {
        guard let marker = PlayerMarkerMath.nextMarker(markers, after: currentSeconds, preroll: PlaybackCoordinator.eventPreroll)
        else { return }
        playback.seek(toEventAt: marker.t, eventID: marker.id)
        applyPendingSeek()
    }

    /// "◀ Event" / `[`: to the previous marker, 3 s early (player.js:264-268).
    func goToPreviousEvent(in markers: [TimelineEvent]) {
        guard let marker = PlayerMarkerMath.previousMarker(markers, before: currentSeconds, preroll: PlaybackCoordinator.eventPreroll)
        else { return }
        playback.seek(toEventAt: marker.t, eventID: marker.id)
        applyPendingSeek()
    }

    /// Applies a seek another part of the page asked for (`PlaybackCoordinator.pendingSeek`); while the
    /// film is still opening it waits until it is ready.
    func applyPendingSeek() {
        guard phase == .ready, let seconds = playback.consumePendingSeek() else { return }
        seek(to: seconds)
    }

    /// Seeks to `seconds`, clamped to the film (04 §6.2), exactly (calibration needs the exact frame).
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        guard phase == .ready, player.currentItem != nil else {
            if restore != nil { restore?.time = max(0, seconds) }
            return
        }
        let target = clampedToFilm(seconds)
        seeksInFlight += 1
        seekTarget = target
        playback.currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.seekDidEnd() }
        }
    }

    /// The calibration sheet opens: pause and publish the exact time of the frame shown (04 §6.3).
    func beginCalibrating() {
        isCalibrating = true
        player.pause()
        if phase == .ready {
            let seconds = currentSeconds
            if seconds.isFinite { playback.currentTime = seconds }
        }
    }

    /// The calibration sheet closed: reloads that waited are done now (player.js:149).
    func endCalibrating() {
        guard isCalibrating else { return }
        isCalibrating = false
        if reloadAfterCalibration {
            reloadAfterCalibration = false
            apply()
        }
    }

    // MARK: - Loading (player.js:135-234)

    private func apply() {
        guard activeRuns > 0 else { return }
        if isCalibrating {
            reloadAfterCalibration = true
            return
        }
        guard let inputs, inputs.isPlayable, let factory else {
            clear()
            return
        }
        let arrived = inputs.hasAnnotated && !annotatedListed
        annotatedListed = inputs.hasAnnotated
        let current = Loaded(film: inputs.film, revision: inputs.revision, factoryID: ObjectIdentifier(factory))

        guard let previous = loaded, previous.film == inputs.film else {
            // First load, or another film: from the start, the annotated copy first.
            if loaded != nil { playback.reset() }
            loaded = current
            coachChose = false
            unavailable = []
            refreshAvailability()
            let first = PlayerVariantRules.initial(hasOriginal: hasOriginal, hasAnnotated: hasAnnotated) ?? .original
            load(first, keepTime: false, reload: true)
            return
        }

        // Same film. A new revision (an ANALYZE ended, the overlay copy changed) or a new loader (signed in
        // again) loads the same URL again (09 R12); copies that failed get another chance.
        let renewed = previous.revision != current.revision || previous.factoryID != current.factoryID
        loaded = current
        if renewed { unavailable = [] }
        refreshAvailability()
        let requested = PlayerVariantRules.afterRefresh(current: variant, arrived: arrived, coachChose: coachChose)
            ?? variant
            ?? PlayerVariantRules.initial(hasOriginal: hasOriginal, hasAnnotated: hasAnnotated)
            ?? .original
        let target = PlayerVariantRules.target(requested: requested, hasOriginal: hasOriginal, hasAnnotated: hasAnnotated)
        if renewed || target != variant || player.currentItem == nil {
            load(requested, keepTime: true, reload: true)
        }
    }

    private func refreshAvailability() {
        hasOriginal = (inputs?.hasOriginal ?? false) && !unavailable.contains(.original)
        hasAnnotated = (inputs?.hasAnnotated ?? false) && !unavailable.contains(.annotated)
    }

    /// Loads `requested` (or the copy the rules give for it), keeping the time and the playing state when
    /// asked (player.js:186-213).
    private func load(_ requested: VideoVariant, keepTime: Bool, reload: Bool) {
        guard let inputs, let factory,
              let target = PlayerVariantRules.target(requested: requested, hasOriginal: hasOriginal, hasAnnotated: hasAnnotated)
        else { return }
        if target == variant, player.currentItem != nil, !reload { return }
        let time = keepTime ? currentSeconds : 0
        let resume = keepTime && (restore?.play ?? (player.timeControlStatus != .paused))
        variant = target
        notice = nil
        loadError = nil
        let asset = factory.makeAsset(gameID: inputs.film.gameID, filmFileName: inputs.film.fileName, variant: target)
        let item = AVPlayerItem(asset: asset)
        restore = Restore(time: time, play: resume)
        observe(item)
        phase = .loading
        presentationSize = .zero
        player.replaceCurrentItem(with: item)
    }

    /// No film to play (or signed out).
    private func clear() {
        itemObservations = []
        restore = nil
        if player.currentItem != nil { player.replaceCurrentItem(with: nil) }
        if loaded != nil { playback.reset() }
        loaded = nil
        variant = nil
        phase = .idle
        notice = nil
        loadError = nil
        presentationSize = .zero
        refreshAvailability()
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item else { return }
                    self.itemStatusDidChange(item)
                }
            },
            item.observe(\.presentationSize, options: [.new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.presentationSize = item.presentationSize
                }
            },
            item.observe(\.duration, options: [.new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.publishDuration(of: item)
                }
            },
        ]
    }

    private func itemStatusDidChange(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            becameReady(item)
        case .failed:
            failed(item)
        default:
            break
        }
    }

    private func becameReady(_ item: AVPlayerItem) {
        guard phase != .ready else { return }
        phase = .ready
        PlayerAudioSession.prepareForFilm()
        presentationSize = item.presentationSize
        publishDuration(of: item)
        let restored = restore
        restore = nil
        if let pending = playback.consumePendingSeek() {
            // A seek asked for while the film was opening (a timeline row) wins.
            seek(to: pending)
        } else if let restored, restored.time > 0 {
            seek(to: restored.time)
        } else {
            playback.currentTime = 0
        }
        if restored?.play == true { play() }
    }

    private func publishDuration(of item: AVPlayerItem) {
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0, playback.duration != seconds else { return }
        playback.duration = seconds
    }

    /// A copy failed: fall back to the other one, or say what went wrong (player.js:215-234).
    private func failed(_ item: AVPlayerItem) {
        phase = .failed
        let failedVariant = variant ?? .original
        let failure = PlayerFailure.classify(item.error)
        // A 401 / lockout: the gate already stopped everything and shows the sign-in screen.
        if factory?.stopError != nil { return }
        switch failure {
        case .server, .undecodable:
            // This copy will not play: the other one is tried, and this one is not offered again until
            // the film is loaded anew.
            unavailable.insert(failedVariant)
        case .connection, .cancelled:
            break
        }
        refreshAvailability()
        switch PlayerVariantRules.afterFailure(failure, failed: failedVariant, hasOriginal: hasOriginal, hasAnnotated: hasAnnotated) {
        case .ignore:
            break
        case .showError:
            loadError = presentableError(for: failure, error: item.error)
        case .fallBack(let other, let text):
            load(other, keepTime: true, reload: true)
            notice = text
        case .cannotPlay(let text):
            notice = text
        }
    }

    /// The error to show for a failed film request, through the lockout gate (nil: nothing to show).
    private func presentableError(for failure: PlayerFailure, error: (any Error)?) -> (any PresentableError)? {
        let client = factory?.client
        let lastError = factory?.lastError
        switch failure {
        case .connection:
            if let lastError, lastError.urlError != nil { return report(lastError, client) }
            let transport = PlayerFailure.underlyingError(of: error, domain: NSURLErrorDomain) ?? URLError(.networkConnectionLost) as NSError
            return report(APIError.from(transportError: transport, url: nil), client)
        case .server(let status):
            if let lastError, lastError.status == status { return report(lastError, client) }
            let reason = PlayerFailure.underlyingError(of: error, domain: VideoResourceLoader.errorDomain)
            return DisplayError(
                title: reason?.localizedDescription ?? "Film unavailable",
                message: reason?.localizedFailureReason ?? "The server could not send the film (status \(status)).",
                isRetryable: status >= 500)
        case .cancelled, .undecodable:
            return nil
        }
    }

    private func clampedToFilm(_ seconds: Double) -> Double {
        var upper = playback.duration
        if upper == nil, let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            upper = itemDuration
        }
        var value = max(0, seconds)
        if let upper { value = min(value, upper) }
        return value
    }

    // MARK: - Observing the player (only while a view runs)

    private func startObserving() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.timeUpdateInterval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeDidChange(time) }
        }
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.playingStateDidChange() }
            },
            player.observe(\.rate, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.rateDidChange() }
            },
        ]
    }

    private func stopObserving() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations = []
    }

    private func timeDidChange(_ time: CMTime) {
        guard seeksInFlight == 0, phase == .ready else { return }
        let seconds = time.seconds
        guard seconds.isFinite, abs(playback.currentTime - seconds) > 0.001 else { return }
        playback.currentTime = seconds
    }

    private func playingStateDidChange() {
        let playing = player.timeControlStatus != .paused
        if playback.isPlaying != playing { playback.isPlaying = playing }
    }

    /// The system controls changed the speed: the menu follows.
    private func rateDidChange() {
        let rate = Double(player.rate)
        if rate > 0, abs(rate - playback.rate) > 0.001 { playback.rate = rate }
    }

    private func seekDidEnd() {
        seeksInFlight = max(0, seeksInFlight - 1)
        guard seeksInFlight == 0 else { return }
        seekTarget = nil
        guard phase == .ready else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { playback.currentTime = seconds }
    }

    // MARK: - Types

    private struct Loaded: Equatable {
        var film: PlayerFilmInputs.Film
        var revision: Int
        var factoryID: ObjectIdentifier
    }

    /// Where to continue once the new item is ready.
    private struct Restore {
        var time: Double
        var play: Bool
    }
}

/// The audio of game film (iPhone, iPad): plays like a video app's, also with the silent switch on, and
/// pauses other audio while the film plays. Set once, the first time a film is ready; no background
/// audio (the app has no audio background mode).
enum PlayerAudioSession {
    private static var isPrepared = false

    static func prepareForFilm() {
        #if os(iOS)
        guard !isPrepared else { return }
        isPrepared = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }
}

extension PlayerFailure {
    /// The first error of `domain` in `error`'s chain of underlying errors.
    nonisolated static func underlyingError(of error: (any Error)?, domain: String) -> NSError? {
        var current = error.map { $0 as NSError }
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == domain { return nsError }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
