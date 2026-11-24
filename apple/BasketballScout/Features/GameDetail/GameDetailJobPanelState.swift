import Foundation

/// What the job panel shows for the latest analysis job (03 §7.3 row 3, §7.5; jobpanel.js), as plain values
/// the view draws. Every text comes from the models (`Job+Derived`).
nonisolated enum GameDetailJobPanelState: Hashable, Sendable {
    /// No analysis job yet, or one that succeeded without warnings.
    case hidden
    /// Queued or running: stage, progress, details, Cancel.
    case active(Active)
    /// Succeeded with warnings: "<kind> finished with warnings" and the list (03 §3.5).
    case finishedWithWarnings(title: String, warnings: [String])
    /// Cancelled: "<kind> was cancelled" with "Start again".
    case cancelled(Finished)
    /// Failed: the job's error with "Re-run analysis", "Retry" or no button.
    case failed(Finished)

    /// A queued or running job.
    nonisolated struct Active: Hashable, Sendable {
        /// The latest polled state of the job (Cancel asks with it).
        var job: Job
        /// "Film analysis in progress".
        var title: String
        /// The stage line: "Analyzing on the GPU (42%)", "Cancelling…".
        var stage: String
        /// 0…1, or nil while queued (an indeterminate bar).
        var fraction: Double?
        /// "42% overall · <message> · running for 3 min 20 s" (the message is left out after a cancel request).
        var details: String
        /// "Cancel", "Cancelling…", "Cancel requested".
        var cancelTitle: String
        /// Cancel is offered until a cancel was requested (or while one is being sent).
        var canCancel: Bool
        /// Waiting in the queue: the worker notice applies (07 §6 loop 4).
        var isQueued: Bool
    }

    /// A cancelled or failed job.
    nonisolated struct Finished: Hashable, Sendable {
        var job: Job
        /// Cancelled: "<kind> was cancelled" / "Start it again whenever you are ready.".
        var notice: NoticeText?
        /// Failed: `error`, or "<kind> failed" with the job's message.
        var error: ErrorInfo?
        /// Start again / Re-run analysis / Retry, or nil (a failure that retrying cannot fix).
        var action: FinishedJobAction?
        /// The action sends the film to the GPU again while the game has GPU results: ask with the Full
        /// re-analysis text first (03 §7.5, 09 D1 #5).
        var needsConfirmation: Bool
    }

    /// - Parameters:
    ///   - job: the latest analysis job (`GameContext.latestAnalysisJob`).
    ///   - gameHasTracking: `Game.has_tracking` (a retry that goes back to the GPU is confirmed first).
    ///   - cancellingJobID: a cancel of this job is being sent: show what it will become and keep it disabled
    ///     (the web changes the button at once, jobpanel.js:205-206).
    ///   - now: the device clock for "running for …" (09 R35: never negative).
    ///   - liveEndedWithoutFilm: the game's live stream ended before any film arrived (`LiveInfo`): a live job
    ///     then has nothing to start again (the server answers `VIDEO_MISSING`), so no button is offered.
    init(job: Job?, gameHasTracking: Bool, cancellingJobID: String?, now: Date, liveEndedWithoutFilm: Bool = false) {
        guard let job else {
            self = .hidden
            return
        }
        if job.isActive {
            let cancelling = cancellingJobID == job.id
            var requested = job
            requested.cancelRequested = true
            self = .active(Active(
                job: job,
                title: job.panelTitle,
                stage: job.stageText,
                fraction: job.status == .queued ? nil : job.progress / 100,
                details: job.panelDetails(runningFor: job.elapsedSeconds(now: now).map { ScoutFormat.duration($0) }),
                cancelTitle: cancelling ? requested.cancelButtonTitle : job.cancelButtonTitle,
                canCancel: !cancelling && !job.cancelRequested,
                isQueued: job.status == .queued))
            return
        }
        let nothingToRestart = job.kind == .live && liveEndedWithoutFilm
        let action = nothingToRestart ? nil : job.finishedAction
        switch job.status {
        case .succeeded:
            self = job.warnings.isEmpty ? .hidden : .finishedWithWarnings(title: job.finishedWithWarningsTitle, warnings: job.warnings)
        case .cancelled:
            var notice = job.cancelledNotice
            if nothingToRestart { notice.message = Job.liveCancelledWithoutFilmMessage }
            self = .cancelled(Finished(
                job: job, notice: notice, error: nil, action: action,
                needsConfirmation: job.retryNeedsConfirmation(gameHasTracking: gameHasTracking)))
        default:
            // Failed, or a status this app does not know: the web shows anything else that ended as a failure.
            self = .failed(Finished(
                job: job, notice: nil, error: job.failureInfo, action: action,
                needsConfirmation: job.retryNeedsConfirmation(gameHasTracking: gameHasTracking)))
        }
    }

    /// The job behind the panel, if it shows one.
    var job: Job? {
        switch self {
        case .hidden, .finishedWithWarnings: nil
        case .active(let active): active.job
        case .cancelled(let finished), .failed(let finished): finished.job
        }
    }

    /// Identifies a panel by its job and that job's final status (the web's `"<id>:<status>"`, jobpanel.js:61;
    /// queued and running are one panel): an error the panel showed belongs to it and goes with it.
    static func key(for job: Job) -> String {
        "\(job.id):\(job.isActive ? "active" : job.status.rawValue)"
    }
}
