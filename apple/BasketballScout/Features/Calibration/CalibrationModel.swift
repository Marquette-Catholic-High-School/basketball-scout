import Foundation
import Observation

/// Everything the court calibration sheet shows and does (04 §5, §6.3; 09 R14, R37, D1 #11).
///
/// **Film.** The sheet shows still frames of the ORIGINAL copy (the annotated one when no original is
/// stored, or when this device cannot decode the original), grabbed exactly from the same asset source as the
/// player (`CalibrationFrameSource`). It opens on the saved calibration's frame (`frame_t`, 04 §8.20), else
/// on the player's position; the coach scrubs and steps to a frame where the floor lines are clear.
///
/// **Points.** `draft` holds the points in the pixels of the copy on screen; Save sends them with that copy's
/// `video_width`/`video_height` and the frame's time (09 D1 #11). A saved calibration is shown on open with
/// its fit verdict and court lines, rescaled when the copy on screen has another size.
///
/// **Server.** Landmarks come from the page (`GameContext`) or are loaded here; the game is refetched when
/// the sheet opens (09 R37) and after a save or removal, so the page's other parts see the new calibration.
/// Every error goes through `ServerSession.report(_:from:)` first.
///
/// **Jobs.** After saving: "Re-run analysis" / "Analyze film" and, when the analysis found no free throws,
/// "Full re-analysis" (confirmed) — through `GameContext.startJob`; the sheet closes once one has started.
@Observable
final class CalibrationModel {
    let context: GameContext

    // MARK: - Landmarks

    /// The server's court and landmarks (04 §5.1).
    private(set) var landmarks: CourtLandmarks?
    private(set) var landmarksError: (any PresentableError)?
    private(set) var isLoadingLandmarks = false

    // MARK: - Points

    /// The points being placed; nil until the landmarks are known.
    private(set) var draft: CalibrationDraft?
    /// The calibration saved on the server, as last seen.
    private(set) var savedCalibration: CourtCalibration?
    /// Grows with every placed point (haptics).
    private(set) var placementCount = 0

    // MARK: - Film

    /// The copy the frames come from.
    private(set) var variant: VideoVariant?
    private(set) var duration: Double?
    private(set) var frameRate: Double?
    /// The frame on screen.
    private(set) var frame: CalibrationFrame?
    /// The frame asked for; the view loads it (`loadRequestedFrame()`).
    private(set) var frameRequest: CalibrationFrameRequest?
    private(set) var isLoadingFrame = false
    private(set) var filmError: (any PresentableError)?
    /// Grows when the film must be prepared again (retry, another copy, new film).
    private(set) var filmAttempt = 0
    /// Why another copy than the original is shown, when it took over after a failure.
    private(set) var fallbackNotice: String?

    // MARK: - Saving and results

    private(set) var isSaving = false
    private(set) var isRemoving = false
    /// The re-run being started from the result.
    private(set) var startingJob: JobChoice?
    /// The result area's notice after a removal or a failed save/removal.
    private(set) var outcome: Outcome?
    /// Starting a job failed.
    private(set) var jobError: (any PresentableError)?
    /// The fit result was just saved: VoiceOver reads it (the web's live region).
    private(set) var announcesFit = false
    /// Grows when a save or removal has finished (the panel scrolls to its result).
    private(set) var resultRevision = 0
    /// A question to confirm (remove, Full re-analysis, close with changes).
    var confirmation: ConfirmationRequest?
    /// The sheet should close.
    private(set) var shouldDismiss = false
    /// Short messages inside the sheet ("Tap inside the picture, …"); the app's toasts sit behind it.
    let messages = ToastCenter()

    // MARK: - Dependencies

    @ObservationIgnored private let makeSource: CalibrationFrameSourceMaker
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private var source: (any CalibrationFrameSource)?
    @ObservationIgnored private var hasFilmInfo = false
    @ObservationIgnored private var preferredVariant: VideoVariant?
    @ObservationIgnored private var loadedRequest: CalibrationFrameRequest?
    @ObservationIgnored private var requestSerial = 0
    @ObservationIgnored private var didRefreshContext = false
    @ObservationIgnored private var linesCache: LinesCache?

    /// How long scrubbing waits for the slider to rest before decoding a frame.
    static let scrubDelay: Duration = .milliseconds(150)

    /// What the result's buttons start.
    nonisolated enum JobChoice: Hashable, Sendable {
        /// "Re-run analysis" / "Analyze film" (the game's re-run kind).
        case rerun
        /// "Full re-analysis" (ANALYZE: the film goes to the GPU again).
        case full
    }

    /// The result area's notice.
    enum Outcome {
        /// "Calibration removed. …" (info).
        case removed(String)
        /// Saving failed ("Try again" saves again when the error is retryable).
        case saveFailed(any PresentableError)
        /// Removing failed.
        case removeFailed(any PresentableError)
    }

    /// A group of the landmark picker.
    nonisolated struct LandmarkSection: Identifiable, Sendable {
        let group: CourtLandmark.Group
        let landmarks: [CourtLandmark]
        var id: CourtLandmark.Group { group }
    }

    private nonisolated struct LinesCache: Sendable {
        var matrix: [[Double]]
        var court: CourtDimensions
        var lines: [[XY?]]
    }

    /// - Parameters:
    ///   - frameSources: makes the frame source for a copy of the film (nil: the session's film loader).
    ///   - sleeper: waits while the slider moves (tests return at once).
    init(context: GameContext, frameSources: CalibrationFrameSourceMaker? = nil, sleeper: Sleeper = .live) {
        self.context = context
        makeSource = frameSources ?? CalibrationFilmFrameSource.maker(for: context)
        self.sleeper = sleeper
        savedCalibration = context.game?.calibration
        if let known = context.landmarks ?? context.session.courtLandmarks { adopt(known) }
    }

    // MARK: - Derived

    /// The film task's identity: a retry, another copy, a new film, or the game becoming playable restarts it.
    var filmTaskID: String { "\(filmAttempt)|\(context.game?.isPlayable == true)" }

    /// The game cannot be calibrated: no stored film and no annotated copy (calibrate.js:111-113; 04 §8.16).
    var unavailableMessage: String? {
        guard let game = context.game, !game.isPlayable else { return nil }
        return game.videoURL != nil ? CalibrationText.linkFilmWithoutCopy : CalibrationText.noFilm
    }

    /// The frame and panel are shown (film to calibrate on, game and landmarks loaded).
    var showsEditor: Bool { unavailableMessage == nil && context.game != nil && draft != nil }

    /// Why the annotated copy is shown, if it is.
    var filmNotice: String? {
        if let fallbackNotice { return fallbackNotice }
        guard variant == .annotated, let game = context.game, !game.hasVideo else { return nil }
        return game.videoURL != nil ? CalibrationText.linkFilmCopy : CalibrationText.annotatedOnlyCopy
    }

    /// The placed points, in the pixels of the frame on screen.
    var points: [CalibrationPoint] { draft?.points ?? [] }

    /// The landmark the next click places.
    var selectedLandmark: String? {
        get { draft?.selectedLandmark }
        set { draft?.selectedLandmark = newValue }
    }

    var selectedLabel: String? {
        guard let draft, let name = draft.selectedLandmark else { return nil }
        return draft.label(for: name)
    }

    /// 04 §8.18: the selected landmark is the same court spot as another one.
    var selectedSameSpotNote: String? {
        guard let draft, let name = draft.selectedLandmark, let other = draft.sameSpotLandmarks(as: name).first else { return nil }
        return CalibrationText.sameSpotNote(other.label, otherNumber: draft.number(of: other.name))
    }

    /// The picker's groups, in the documented order (calibrate.js:95-103).
    var landmarkSections: [LandmarkSection] {
        (landmarks?.grouped ?? []).map { LandmarkSection(group: $0.group, landmarks: $0.landmarks) }
    }

    /// A picker option: the web's label, plus the point's number once placed.
    func optionTitle(for landmark: CourtLandmark) -> String {
        guard let number = draft?.number(of: landmark.name) else { return landmark.label }
        return CalibrationText.placedOption(landmark.label, number: number)
    }

    var countText: String { draft?.countText ?? CalibrationText.count(0) }
    var tip: String? { draft?.tip }
    var warnings: [CalibrationWarning] { draft?.warnings ?? [] }
    var hasUnsavedChanges: Bool { draft?.isDirty ?? false }
    /// "Changes not saved yet." while a saved calibration is being edited.
    var showsUnsavedNote: Bool { hasUnsavedChanges && savedCalibration != nil }
    var canEdit: Bool { draft != nil && frame != nil }
    var canUndo: Bool { draft?.canUndo ?? false }
    var canClear: Bool { !(draft?.points.isEmpty ?? true) }
    /// Save needs 4 points and a frame on screen (its size is the pixel space).
    var canSave: Bool { (draft?.canSave ?? false) && frame != nil && !isSaving && !isRemoving }
    var hasSavedCalibration: Bool { savedCalibration != nil }

    /// The saved calibration whose fit is on screen: while the points are the saved ones (calibrate.js:188-193).
    var fitCalibration: CourtCalibration? {
        draft?.matrix != nil ? savedCalibration : nil
    }

    /// The court lines to draw on the frame (pixels; nil breaks a line), while a fit is on screen.
    var projectedLines: [[XY?]] {
        guard let matrix = draft?.matrix, let court = landmarks?.court else { return [] }
        if let linesCache, linesCache.matrix == matrix, linesCache.court == court { return linesCache.lines }
        let lines = CalibrationGeometry.projectedLines(CalibrationCourtLines.fullCourt(court), matrix: matrix)
        linesCache = LinesCache(matrix: matrix, court: court, lines: lines)
        return lines
    }

    /// The re-run button's title: "Re-run analysis" with GPU results saved, else "Analyze film".
    var rerunTitle: String { context.game?.rerunButtonTitle ?? "Analyze film" }

    /// The game page's re-run help ("Redo the stats on this server …"), when not busy.
    var rerunHelp: String? { jobsBlocked ? Game.analysisRunningHelp : context.game?.rerunHelp }

    /// "Full re-analysis" is offered: film to send, and the analysis found no free throws (game.js:45, 145).
    var offersFullReanalysis: Bool {
        context.hasFilm && (context.analysis?.freeThrowsMissing ?? false)
    }

    /// The result's buttons wait while an analysis is queued or running (calibrate.js:268-275).
    var jobsBlocked: Bool { context.isBusy || context.isStartingJob || startingJob != nil }

    var resultHint: String { CalibrationText.resultHint(fullRunAdvised: offersFullReanalysis) }

    /// The time the scrubber shows: the frame on screen once it is the one asked for, else the one asked for.
    var displayTime: Double {
        if let frame, let frameRequest, loadedRequest == frameRequest { return frame.time }
        return frameRequest?.time ?? frame?.time ?? 0
    }

    /// The saved calibration's frame time (04 §8.20), when there is one.
    var savedFrameTime: Double? {
        guard let time = savedCalibration?.frameT, time.isFinite, time >= 0 else { return nil }
        return time
    }

    var canGoToSavedFrame: Bool {
        guard let savedFrameTime, duration != nil else { return false }
        return abs(savedFrameTime - displayTime) > frameStep / 2
    }

    /// Seconds per frame (30 fps when the rate is unknown).
    var frameStep: Double { 1 / (frameRate ?? 30) }

    /// What VoiceOver says about the frame.
    var frameAccessibilityValue: String {
        var parts = [ScoutFormat.spokenClock(displayTime), countText]
        if let selectedLabel { parts.append(CalibrationText.selectedLandmark(selectedLabel)) }
        return parts.joined(separator: ". ")
    }

    // MARK: - Lifecycle

    /// Loads what the sheet needs: refetches the game once (09 R37) and the landmarks when the page has none.
    /// Run it from `.taskWhileActive`; it can run again after the app returns to the foreground.
    func start() async {
        if landmarks == nil, let known = context.landmarks ?? context.session.courtLandmarks { adopt(known) }
        if !didRefreshContext {
            didRefreshContext = true
            await context.refresh()
            syncWithContext()
        }
        if landmarks == nil { await loadLandmarks() }
    }

    /// `GET /api/court/landmarks` (04 §5.1), when the page could not load them.
    func loadLandmarks() async {
        guard landmarks == nil, !isLoadingLandmarks, let client = context.client else { return }
        isLoadingLandmarks = true
        landmarksError = nil
        do {
            let loaded = try await client.courtLandmarks()
            isLoadingLandmarks = false
            context.session.updateCourtLandmarks(loaded)
            adopt(loaded)
        } catch {
            isLoadingLandmarks = false
            landmarksError = context.session.report(error, from: client)
        }
    }

    /// Takes in what the page knows now: landmarks it loaded, and a calibration saved elsewhere (another
    /// device, 09 R37). Unsaved points are kept; otherwise the newly saved calibration is shown.
    func syncWithContext() {
        if landmarks == nil, let known = context.landmarks { adopt(known) }
        guard let game = context.game else { return }
        let server = game.calibration
        guard server != savedCalibration else { return }
        // An answer from before our own save (newest refresh wins, but stay safe).
        if let mine = savedCalibration?.createdAt, let theirs = server?.createdAt, theirs < mine { return }
        savedCalibration = server
        announcesFit = false
        guard draft != nil else { return }
        if draft?.isDirty == true {
            draft?.replaceSaved(server)
        } else {
            draft?.load(server, currentSize: frame?.size)
            outcome = nil
        }
    }

    private func adopt(_ loaded: CourtLandmarks) {
        landmarks = loaded
        landmarksError = nil
        guard draft == nil else { return }
        var created = CalibrationDraft(landmarks: loaded.landmarks)
        created.load(savedCalibration, currentSize: frame?.size)
        draft = created
    }

    // MARK: - Film

    /// The copy the sheet starts with: the original when stored, else the annotated one (calibrate.js:119,
    /// player.js:295-304).
    static func initialVariant(for game: Game) -> VideoVariant? {
        if game.hasVideo { return .original }
        if game.hasAnnotatedVideo { return .annotated }
        return nil
    }

    /// Makes the frame source, reads the film's length and asks for the first frame. Run it from
    /// `.taskWhileActive(id: filmAttempt)`.
    func prepareFilm() async {
        guard let game = context.game else { return }
        if source == nil {
            guard let variant = preferredVariant ?? Self.initialVariant(for: game) else { return }
            guard let made = makeSource(game, variant) else {
                filmError = ServerSessionError.notSignedIn
                return
            }
            source = made
            self.variant = variant
            preferredVariant = variant
        }
        guard let current = source, !hasFilmInfo else { return }
        let attempt = filmAttempt
        do {
            let info = try await current.loadInfo()
            guard attempt == filmAttempt, source === current else { return }
            hasFilmInfo = true
            duration = info.duration
            frameRate = info.frameRate
            filmError = nil
            requestFrame(at: frameRequest?.time ?? initialTime(), debounce: false)
        } catch {
            guard !Task.isCancelled, attempt == filmAttempt, source === current else { return }
            handleFilmFailure(error)
        }
    }

    /// Loads the frame asked for (after a short wait while scrubbing). Run it from
    /// `.taskWhileActive(id: frameRequest)`: a newer request cancels this one.
    func loadRequestedFrame() async {
        guard let request = frameRequest, request != loadedRequest, request.attempt == filmAttempt, let current = source else {
            return
        }
        if request.debounce {
            do { try await sleeper.sleep(for: Self.scrubDelay) } catch { return }
        }
        isLoadingFrame = true
        do {
            let loaded = try await current.frame(at: request.time)
            if frameRequest == request { isLoadingFrame = false }
            guard !Task.isCancelled, frameRequest == request, source === current else { return }
            loadedRequest = request
            show(loaded)
            filmError = nil
        } catch {
            if frameRequest == request { isLoadingFrame = false }
            guard !Task.isCancelled, frameRequest == request, source === current else { return }
            handleFilmFailure(error)
        }
    }

    /// Asks for the frame at `seconds` (clamped to the film).
    func requestFrame(at seconds: Double, debounce: Bool) {
        requestSerial += 1
        frameRequest = CalibrationFrameRequest(serial: requestSerial, attempt: filmAttempt, time: clampedTime(seconds), debounce: debounce)
    }

    /// The slider moved.
    func scrub(to seconds: Double) {
        requestFrame(at: seconds, debounce: true)
    }

    /// Steps by whole seconds from the time asked for (presses add up while a frame loads).
    func step(seconds: Double) {
        requestFrame(at: (frameRequest?.time ?? displayTime) + seconds, debounce: false)
    }

    /// Steps by frames: to the middle of the frame `count` frames away from the one on screen.
    func stepFrames(_ count: Int) {
        let base = loadedRequest == frameRequest ? (frame?.time ?? displayTime) : (frameRequest?.time ?? displayTime)
        // Frame k spans [k, k + 1) × step: +1 → base + 1.5 steps, −1 → base − 0.5 steps.
        requestFrame(at: base + (Double(count) + 0.5) * frameStep, debounce: false)
    }

    /// Back to the frame the saved calibration was measured on (04 §8.20).
    func goToSavedFrame() {
        guard let savedFrameTime else { return }
        requestFrame(at: savedFrameTime, debounce: false)
    }

    /// "Try again" after a film error.
    func retryFilm() {
        filmError = nil
        resetSource()
    }

    /// The page's film changed (new film, new annotated copy): load it again.
    func filmChanged() {
        preferredVariant = nil
        fallbackNotice = nil
        resetSource()
    }

    private func resetSource() {
        source = nil
        hasFilmInfo = false
        loadedRequest = nil
        filmAttempt += 1
    }

    private func initialTime() -> Double {
        if let savedFrameTime, duration.map({ savedFrameTime <= $0 }) ?? true { return savedFrameTime }
        return context.playback.currentTime
    }

    /// Within the film: from 0 to the middle of its last frame.
    func clampedTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        var time = max(0, seconds)
        if let duration { time = min(time, max(0, duration - frameStep / 2)) }
        return time
    }

    private func show(_ loaded: CalibrationFrame) {
        frame = loaded
        draft?.fit(to: loaded.size)
    }

    private func handleFilmFailure(_ error: any Error) {
        if ServerSession.isCancellation(error) { return }
        switch error as? CalibrationFilmFailure ?? .unreadable {
        case .request(let apiError?) where apiError.isCancellation:
            return
        case .request(let apiError?):
            // The film loader already reported it to the lockout gate (09 R6); show the rest.
            filmError = apiError.stopsAllRequests ? nil : apiError
        case .request(nil):
            filmError = DisplayError(
                title: CalibrationText.filmFailedTitle, message: CalibrationText.filmFailedMessage,
                hint: CalibrationText.filmFailedHint, isRetryable: true)
        case .unreadable:
            if variant == .original, context.game?.hasAnnotatedVideo == true {
                // player.js:215-234: the annotated copy takes over; points are rescaled to it.
                preferredVariant = .annotated
                fallbackNotice = CalibrationText.annotatedFallback
                resetSource()
            } else {
                filmError = DisplayError(
                    title: CalibrationText.unreadableTitle, message: CalibrationText.unreadableMessage,
                    hint: CalibrationText.unreadableHint, isRetryable: true)
            }
        }
    }

    // MARK: - Points

    /// Selects a landmark (picker, diagram, list, or a click on its point).
    func select(_ name: String) {
        draft?.selectedLandmark = name
    }

    /// Selects the next or previous landmark (VoiceOver's adjustable diagram).
    func selectAdjacent(forward: Bool) {
        guard let draft, !draft.landmarks.isEmpty else { return }
        let names = draft.landmarks.map(\.name)
        let index = draft.selectedLandmark.flatMap { names.firstIndex(of: $0) } ?? -1
        let next = forward ? min(index + 1, names.count - 1) : max(index - 1, 0)
        select(names[next])
    }

    /// A click on the frame: places the selected landmark there; outside the picture the web's message
    /// (calibrate.js:172-186).
    func tap(atPixel pixel: XY?) {
        guard draft != nil, frame != nil else { return }
        guard let pixel, draft?.selectedLandmark != nil else {
            messages.show(CalibrationText.outsidePicture)
            return
        }
        changeDraft { $0.place(at: pixel) }
        placementCount += 1
    }

    /// A drag of the point of `name` starts.
    func beginMove(_ name: String) {
        draft?.beginMove()
    }

    /// The dragged point is now at `pixel`.
    func move(_ name: String, to pixel: XY) {
        changeDraft { $0.setPosition(of: name, to: pixel) }
    }

    func endMove() {
        draft?.endMove()
    }

    func cancelMove() {
        draft?.cancelMove()
    }

    func remove(_ name: String) {
        changeDraft { $0.remove(name) }
    }

    /// Removes the selected landmark's point (Delete key).
    func removeSelectedPoint() {
        guard let name = draft?.selectedLandmark, draft?.point(for: name) != nil else { return }
        remove(name)
    }

    func undo() {
        changeDraft { $0.undo() }
    }

    func clear() {
        changeDraft { $0.clear() }
    }

    /// Any change hides the result until the next save (calibrate.js:188-193).
    private func changeDraft(_ change: (inout CalibrationDraft) -> Void) {
        guard draft != nil else { return }
        change(&draft!)
        if outcome != nil { outcome = nil }
        if jobError != nil { jobError = nil }
        if announcesFit { announcesFit = false }
    }

    // MARK: - Saving (04 §5.2)

    /// `PUT /api/games/{id}/calibration` with the points in the pixels of the copy on screen, its size and the
    /// frame's time; then the result. The page and the games list take the saved calibration as answered
    /// (`GameContext.updateCalibration`, game.js `onChange`), without reloading the page.
    func save() async {
        guard canSave, let client = context.client, let current = draft else { return }
        let request = current.request(frameTime: frame?.time)
        let sentSize = current.frameSize
        isSaving = true
        outcome = nil
        jobError = nil
        do {
            let saved = try await client.saveCalibration(gameID: context.gameID, request)
            isSaving = false
            savedCalibration = saved
            draft?.didSave(saved, sentPoints: request.points, sentSize: sentSize)
            announcesFit = true
            resultRevision += 1
            context.updateCalibration(saved)
        } catch {
            isSaving = false
            if let shown = context.session.report(error, from: client) {
                outcome = .saveFailed(shown)
                resultRevision += 1
            }
        }
    }

    /// Asks before removing the saved calibration (calibrate.js:278).
    func requestRemoveSaved() {
        confirmation = ConfirmationRequest(
            title: CalibrationText.removeQuestion, confirmTitle: CalibrationText.removeConfirm, isDestructive: true
        ) { [weak self] in
            Task { [weak self] in await self?.removeSaved() }
        }
    }

    /// `DELETE /api/games/{id}/calibration` (04 §5.3): the points go too, and the notice says what happens next.
    /// The page and the games list drop the calibration without reloading the page.
    func removeSaved() async {
        guard let client = context.client, !isRemoving else { return }
        isRemoving = true
        outcome = nil
        jobError = nil
        do {
            try await client.deleteCalibration(gameID: context.gameID)
            isRemoving = false
            savedCalibration = nil
            draft?.didRemoveSaved()
            announcesFit = false
            outcome = .removed(CalibrationText.removed(rerunKind: context.rerunKind))
            resultRevision += 1
            context.updateCalibration(nil)
        } catch {
            isRemoving = false
            if let shown = context.session.report(error, from: client) {
                outcome = .removeFailed(shown)
                resultRevision += 1
            }
        }
    }

    // MARK: - Jobs (04 §6.3, game.js:286-306)

    /// "Re-run analysis" (REANALYZE) or "Analyze film" (ANALYZE, no GPU results yet).
    func startRerun() async {
        let kind = context.rerunKind
        await startJob(kind, choice: .rerun, toast: kind.startedToast)
    }

    /// Asks before a Full re-analysis (game.js:25-30).
    func requestFullReanalysis() {
        let text = Game.fullReanalysisConfirmation(showsResults: context.analysis != nil)
        confirmation = ConfirmationRequest(
            title: text.title, message: text.message, confirmTitle: CalibrationText.sendToGPU, isDestructive: false
        ) { [weak self] in
            Task { [weak self] in await self?.startFullReanalysis() }
        }
    }

    /// ANALYZE: the film goes to the GPU again with the calibration (the only way to find missed free throws).
    func startFullReanalysis() async {
        await startJob(.analyze, choice: .full, toast: Labels.fullReanalysisStartedToast)
    }

    private func startJob(_ kind: JobKind, choice: JobChoice, toast: String) async {
        guard !jobsBlocked else { return }
        startingJob = choice
        jobError = nil
        do {
            try await context.startJob(kind)
            startingJob = nil
            context.toasts?.show(toast)
            // The job panel on the game page follows it from here.
            shouldDismiss = true
        } catch {
            startingJob = nil
            if let shown = context.session.report(error, from: context.client) { jobError = shown }
        }
    }

    // MARK: - Closing

    /// "Close": asks first when points were placed or moved since the last save.
    func requestClose() {
        guard hasUnsavedChanges else {
            shouldDismiss = true
            return
        }
        confirmation = ConfirmationRequest(
            title: CalibrationText.closeQuestion, message: CalibrationText.closeMessage,
            confirmTitle: CalibrationText.discardChanges, isDestructive: true, cancelTitle: CalibrationText.keepEditing
        ) { [weak self] in
            self?.shouldDismiss = true
        }
    }
}

/// One frame the sheet asked for. Every request is new (`serial`), so asking again reloads.
nonisolated struct CalibrationFrameRequest: Hashable, Sendable {
    var serial: Int
    /// The film preparation it belongs to (`CalibrationModel.filmAttempt`).
    var attempt: Int
    var time: Double
    /// Wait for the slider to rest first.
    var debounce: Bool
}
