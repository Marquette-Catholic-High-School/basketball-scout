import Foundation
import Observation

/// The game page's actions and what they need on top of `GameContext` (03 §7.4–§7.6): the header's
/// Re-run analysis / Analyze film and Full re-analysis, the job panel's Cancel and Start again / Retry /
/// Re-run analysis, and the "Which team is …?" choice, with their busy states, confirmations, toasts and
/// errors. `GameView` creates one per page next to the page's `GameContext` and puts both in the environment.
///
/// - Every error goes through `ServerSession.report(_:from:)` first (lockout gate, 09 R6); nil means it was
///   a cancellation or the gate handled it, so nothing is shown.
/// - Errors of the header actions and the team choice go to the page error area (game.js `showError(page-error)`);
///   errors of Cancel and Start again / Retry stay in the job panel (jobpanel.js).
/// - The model starts no timers and sends nothing on its own; loading and polling are `GameContext.run()`'s.
@Observable
final class GameDetailModel {
    /// The page's data (game, analysis, jobs) and its job tracking.
    let context: GameContext

    /// The last header-action or team-choice error, with the page as it was then.
    private(set) var actionError: (any PresentableError)?
    private(set) var actionErrorKey: GameDetailStateKey?
    /// A cancel of this job is being sent.
    private(set) var cancellingJobID: String?
    /// Start again / Retry / Re-run analysis of this job is being sent.
    private(set) var restartingJobID: String?
    /// The last Cancel / Start again / Retry error, and the panel it belongs to.
    private(set) var panelError: (any PresentableError)?
    private(set) var panelErrorKey: String?
    /// The jersey colour (pipeline team id) whose choice is being saved.
    private(set) var savingTeamID: Int?
    /// "End live game" is being sent to the server (docs/LIVE.md).
    private(set) var isEndingLive = false
    /// A question to confirm before a costly or destructive action; the page presents it.
    var confirmation: ConfirmationRequest?

    @ObservationIgnored private let toasts: ToastCenter?
    @ObservationIgnored private let now: () -> Date
    #if os(macOS)
    /// The Mac's live captures: "End live game" goes through this Mac's capture when it captures the game.
    @ObservationIgnored private let liveCapture: LiveCaptureCenter?
    #endif

    /// - Parameters:
    ///   - toasts: "Analysis started", "Re-running the analysis…", "Full re-analysis started", "Thanks - teams
    ///     confirmed." (07 §5.2).
    ///   - now: the device clock for the job panel's "running for …".
    init(context: GameContext, toasts: ToastCenter?, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.toasts = toasts
        self.now = now
        #if os(macOS)
        self.liveCapture = nil
        #endif
    }

    #if os(macOS)
    /// - Parameter liveCapture: the app's live captures (`AppModel.liveCapture`).
    init(context: GameContext, toasts: ToastCenter?, liveCapture: LiveCaptureCenter?, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.toasts = toasts
        self.now = now
        self.liveCapture = liveCapture
    }
    #endif

    // MARK: - What the page shows

    /// The page head; nil until the game is loaded.
    var header: GameDetailHeaderState? {
        guard let game = context.game else { return nil }
        return GameDetailHeaderState(
            game: game, analysis: context.analysis, palette: context.teamPalette, badge: context.headerBadge)
    }

    /// The header actions; nil until the game is loaded.
    var actions: GameDetailActionState? {
        guard let game = context.game else { return nil }
        return GameDetailActionState(game: game, isBusy: context.isBusy, isStarting: isWorking)
    }

    /// A job is being started or retried, or a team choice is being saved: the start buttons stay disabled
    /// meanwhile (03 §8: no double taps).
    var isWorking: Bool {
        context.isStartingJob || savingTeamID != nil || restartingJobID != nil
    }

    /// The job panel for the latest analysis job.
    var jobPanel: GameDetailJobPanelState {
        GameDetailJobPanelState(
            job: context.latestAnalysisJob, gameHasTracking: context.game?.hasTracking ?? false,
            cancellingJobID: cancellingJobID, now: now(),
            liveEndedWithoutFilm: context.game?.live?.endedWithoutFilm ?? false)
    }

    /// The buttons of the "Which team is …?" banner; empty when it is not due.
    var teamChoices: [GameDetailTeamChoice] {
        guard let game = context.game, let analysis = context.analysis else { return [] }
        return GameDetailTeamChoice.choices(for: analysis, game: game)
    }

    /// The page error area: the action error while the page still looks as it did when the action failed,
    /// else the load error of the page (game or analysis).
    var pageError: GameDetailPageError? {
        if let actionError, actionErrorKey == stateKey { return .action(actionError) }
        guard let loadError = context.loadError else { return nil }
        let isGone = (loadError as? APIError)?.isNotFound ?? false
        return .load(loadError, canGoBack: context.game == nil || isGone)
    }

    /// The job panel's own error (Cancel, Start again, Retry), while the panel shows the job it was for.
    var visiblePanelError: (any PresentableError)? {
        guard let panelError, let job = context.latestAnalysisJob,
              panelErrorKey == GameDetailJobPanelState.key(for: job)
        else { return nil }
        return panelError
    }

    private var stateKey: GameDetailStateKey {
        GameDetailStateKey(game: context.game, latestAnalysisJob: context.latestAnalysisJob, loadError: context.loadError)
    }

    // MARK: - Header actions (03 §7.4)

    /// "Re-run analysis" / "Analyze film": starts at once without asking (game.js:301-304), then toasts
    /// "Re-running the analysis…" or "Analysis started". On an error the page is reloaded and the error shown.
    func rerun() async {
        guard let actions, actions.canRerun else { return }
        clearActionError()
        await start(actions.rerunKind, toast: actions.rerunToast)
    }

    /// "Full re-analysis": asks first with the web's text (the bracketed sentence only while results are on
    /// the page, 03 §7.4), then starts an ANALYZE.
    func requestFullReanalysis() {
        guard let actions, actions.canFullReanalysis else { return }
        let text = Game.fullReanalysisConfirmation(showsResults: context.analysis != nil)
        confirmation = ConfirmationRequest(
            title: text.title, message: text.message, confirmTitle: GameDetailText.sendToGPU, isDestructive: true
        ) { [weak self] in
            Task { await self?.startFullReanalysis() }
        }
    }

    /// The confirmed Full re-analysis: `POST …/jobs {"kind":"analyze"}`, toast "Full re-analysis started".
    func startFullReanalysis() async {
        guard let actions, actions.canFullReanalysis else { return }
        clearActionError()
        await start(.analyze, toast: Labels.fullReanalysisStartedToast)
    }

    /// Starts a job through the page (it follows the job and reloads), then toasts; errors go to the page
    /// error area after the reload (game.js `startJob`; 09 R36).
    private func start(_ kind: JobKind, toast: String) async {
        let client = context.client
        do {
            try await context.startJob(kind)
            toasts?.show(toast)
        } catch {
            showActionError(error, from: client)
        }
    }

    // MARK: - Live games (docs/LIVE.md)

    /// The live banner; nil for a game that is not live.
    var liveBanner: LiveBannerState? {
        guard let live = context.game?.live, live.isActive else { return nil }
        return LiveBannerState(live: live)
    }

    /// What the running live job warns about (a part that could not be analysed, stats that could not be
    /// rebuilt): the job panel lists a job's warnings only once it has ended, so the live banner shows them
    /// during the game.
    var liveWarnings: [String] {
        guard let job = context.latestAnalysisJob, job.kind == .live, job.isActive else { return [] }
        return job.warnings
    }

    /// This Mac's capture of the game is sending its last parts after "End live game".
    var isCaptureFinishing: Bool {
        #if os(macOS)
        liveCapture?.controller(for: context.gameID)?.phase == .finishing
        #else
        false
        #endif
    }

    /// "End live game" is offered: the game still takes film and no end is under way.
    var canEndLive: Bool {
        context.game?.live?.isCapturing == true && !isEndingLive && !isCaptureFinishing
    }

    /// "End live game": asks first. On the Mac that captures the game the question says what the Mac does.
    func requestEndLive() {
        guard canEndLive else { return }
        confirmation = ConfirmationRequest(
            title: LiveText.endQuestionTitle,
            message: capturesThisGame ? LiveText.endQuestionCaptureMessage : LiveText.endQuestionMessage,
            confirmTitle: LiveText.endConfirm, isDestructive: true, cancelTitle: LiveText.endCancel
        ) { [weak self] in
            Task { await self?.endLive() }
        }
    }

    /// The confirmed end. When this Mac captures the game, its capture ends it (ffmpeg is stopped, the last
    /// parts are sent, then the server is told); otherwise `POST /api/games/{id}/live/finish`. Errors go to
    /// the page error area.
    func endLive() async {
        guard canEndLive else { return }
        clearActionError()
        #if os(macOS)
        if let capture = liveCapture?.controller(for: context.gameID), capture.isActive {
            capture.end()
            return
        }
        #endif
        let client = context.client
        isEndingLive = true
        defer { isEndingLive = false }
        do {
            try await context.finishLive()
            toasts?.show(LiveText.endedToast)
        } catch {
            showActionError(error, from: client)
        }
    }

    /// This Mac is capturing the game right now.
    private var capturesThisGame: Bool {
        #if os(macOS)
        liveCapture?.controller(for: context.gameID)?.isActive ?? false
        #else
        false
        #endif
    }

    // MARK: - Job panel (03 §7.5)

    /// "Cancel": asks the question for the job's stage (`Job.cancelQuestion`), then sends the cancel, also when
    /// it is too late to stop the job (it then only skips a report not yet started).
    func requestCancel(_ job: Job) {
        guard job.isActive, !job.cancelRequested, cancellingJobID == nil else { return }
        let question = job.cancelQuestion
        confirmation = ConfirmationRequest(
            title: question.title, message: question.message,
            confirmTitle: job.isTooLateToCancel ? GameDetailText.cancelAnyway : GameDetailText.stopJob,
            isDestructive: true, cancelTitle: GameDetailText.keepRunning
        ) { [weak self] in
            Task { await self?.cancel(job) }
        }
    }

    /// Sends the cancel (`POST /api/jobs/{id}/cancel`). Meanwhile the button reads "Cancelling…" or "Cancel
    /// requested" and is disabled; on an error it is enabled again and the error shows in the panel.
    func cancel(_ job: Job) async {
        guard cancellingJobID == nil else { return }
        let client = context.client
        clearPanelError()
        cancellingJobID = job.id
        defer { cancellingJobID = nil }
        do {
            try await context.cancelJob(job)
        } catch {
            if let shown = context.session.report(error, from: client) { setPanelError(shown, for: job) }
        }
    }

    /// "Start again" / "Retry" / "Re-run analysis" of a finished job. Asks first with the Full re-analysis
    /// text when it would send the film to the GPU again while the game has GPU results (03 §7.5).
    func requestRestart(_ job: Job) {
        guard restartingJobID == nil, !context.isStartingJob else { return }
        guard job.retryNeedsConfirmation(gameHasTracking: context.game?.hasTracking ?? false) else {
            Task { await restart(job) }
            return
        }
        let text = Game.fullReanalysisConfirmation(showsResults: context.analysis != nil)
        confirmation = ConfirmationRequest(
            title: text.title, message: text.message, confirmTitle: GameDetailText.sendToGPU, isDestructive: true
        ) { [weak self] in
            Task { await self?.restart(job) }
        }
    }

    /// Sends the retry (`POST /api/jobs/{id}/retry`): the page follows the new job and reloads. The button
    /// reads "Starting…" meanwhile; an error shows in the panel.
    func restart(_ job: Job) async {
        guard restartingJobID == nil, !context.isStartingJob else { return }
        let client = context.client
        clearPanelError()
        restartingJobID = job.id
        defer { restartingJobID = nil }
        do {
            try await context.retryJob(job)
        } catch {
            if let shown = context.session.report(error, from: client) { setPanelError(shown, for: job) }
        }
    }

    /// "Check again" after following the job gave up (5 failures in a row, or one that is not retryable).
    func checkJobAgain() {
        clearPanelError()
        context.checkJobAgain()
    }

    // MARK: - Team confirmation (03 §7.6)

    /// A jersey-colour button: `PATCH /api/games/{id}` with the team map. When the analysis already had that
    /// team as the scouted one: "Thanks - teams confirmed." and a reload; otherwise a re-analysis applies it
    /// ("Re-running the analysis…"). The button reads "Saving…" meanwhile; errors go to the page error area.
    func chooseTeam(_ choice: GameDetailTeamChoice) async {
        guard savingTeamID == nil, !context.isStartingJob, let client = context.client else { return }
        clearActionError()
        savingTeamID = choice.teamID
        defer { savingTeamID = nil }
        do {
            _ = try await client.updateGame(id: context.gameID, choice.update)
        } catch {
            showActionError(error, from: client)
            return
        }
        if choice.keepsCurrentSides {
            toasts?.show(Labels.teamsConfirmedToast, tone: .success)
            await context.refresh()
        } else if context.isLive {
            // docs/LIVE.md: the live job rebuilds the stats when the team colours change; a re-analysis of its
            // own would be refused while the game is live.
            toasts?.show(LiveText.teamsSavedWhileLiveToast, tone: .success)
            await context.refresh()
        } else {
            await start(.reanalyze, toast: JobKind.reanalyze.startedToast)
        }
    }

    // MARK: - Loading

    /// Pull to refresh, "Try again" and the Mac's Refresh button: reloads the page (03 §7.3).
    func refresh() async {
        clearActionError()
        await context.refresh()
    }

    // MARK: - Errors

    private func showActionError(_ error: any Error, from client: APIClient?) {
        guard let shown = context.session.report(error, from: client) else { return }
        actionError = shown
        actionErrorKey = stateKey
    }

    private func clearActionError() {
        actionError = nil
        actionErrorKey = nil
    }

    private func setPanelError(_ error: any PresentableError, for job: Job) {
        // The panel shows the job as the server has it now (it may have been reloaded meanwhile).
        let current = context.latestAnalysisJob.flatMap { $0.id == job.id ? $0 : nil } ?? job
        panelError = error
        panelErrorKey = GameDetailJobPanelState.key(for: current)
    }

    private func clearPanelError() {
        panelError = nil
        panelErrorKey = nil
    }
}
