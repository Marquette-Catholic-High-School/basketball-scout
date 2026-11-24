import Foundation

// What the web computes from a job (labels.js, jobpanel.js, index.js, game.js; 03 §3–§4, §7.5, 07 §3.6).

nonisolated extension Job {
    /// `queued` or `running` (api.js:110-114).
    var isActive: Bool { status.isActive }

    /// Not active: the web stops following a job as soon as it leaves `queued`/`running` (api.js:120-135),
    /// so an unknown status counts as finished too.
    var isTerminal: Bool { !isActive }

    /// A cancel no longer stops this job (`tooLateToStop`, labels.js:135-144; 03 §3.3): it runs to the end
    /// and ends `succeeded`; the cancel only skips a report not yet started.
    var isTooLateToCancel: Bool { kind.tooLateToCancelStages.contains(stage) }

    /// `progress` rounded for display: JavaScript `Math.round(job.progress || 0)` (halves up).
    var progressPercent: Int {
        guard progress.isFinite else { return 0 }
        return Int(progress.rounded(.toNearestOrAwayFromZero))
    }

    /// The stage line (`jobStageText`, labels.js:147-156; 03 §3.2), first rule that applies:
    /// 1. succeeded "Finished", failed "Failed", cancelled "Cancelled";
    /// 2. cancel requested and still stoppable: "Cancelling…";
    /// 3. a report job past `queued`: "Writing scouting report";
    /// 4. a live job at `gpu_processing`: "Analysing the film as it arrives" (its percent only says how many
    ///    of the parts received so far are analysed, so it is left out);
    /// 5. the stage label ("Working" when unknown), with " (NN%)" at `gpu_processing`.
    var stageText: String {
        switch status {
        case .succeeded: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        default: break
        }
        if cancelRequested && !isTooLateToCancel { return "Cancelling…" }
        if kind == .report && stage != .queued { return JobStage.reporting.label }
        if kind == .live && stage == .gpuProcessing { return Self.liveStageText }
        if stage == .gpuProcessing { return "\(stage.label) (\(progressPercent)%)" }
        return stage.label
    }

    /// The note after the stage on the games list (index.js:89-91): after a cancel request "Cancel requested"
    /// when it is too late to stop the job, else nothing (09 D1 #10); otherwise the server's `message`
    /// (nil when empty).
    var progressNote: String? {
        if cancelRequested { return isTooLateToCancel ? "Cancel requested" : nil }
        return message.isEmpty ? nil : message
    }

    /// The games list's progress line (index.js:85-95, 07 §3.6): stage text, "NN%" and the note joined by
    /// " · ", e.g. "Analyzing on the GPU (42%) · 42% · Demo mode: simulating GPU processing (42%)".
    var progressText: String {
        [stageText, "\(progressPercent)%", progressNote ?? ""].filter { !$0.isEmpty }.joined(separator: Labels.separator)
    }

    /// The stage line of a live job while the game is played (docs/LIVE.md: the stage stays `gpu_processing`).
    static let liveStageText = "Analysing the film as it arrives"

    /// The games list's text when a game is busy but its job could not be loaded (index.js:92).
    static let waitingForWorkerText = "Waiting for the worker…"

    /// The job panel title (jobpanel.js:130): "<kind label> in progress".
    var panelTitle: String { "\(kind.label) in progress" }

    /// The job panel's details line (jobpanel.js:137-138): "NN% overall", the server's message (left out once
    /// a cancel was requested) and "running for <duration>" when `runningFor` (formatted elsewhere) is given.
    func panelDetails(runningFor: String?) -> String {
        let message = cancelRequested ? nil : (self.message.isEmpty ? nil : self.message)
        let parts = ["\(progressPercent)% overall", message, runningFor.map { "running for \($0)" }]
        return parts.compactMap { $0 }.joined(separator: Labels.separator)
    }

    /// Seconds since `started_at`, never negative (device clock vs server clock, 09 R35); nil before the
    /// first claim. Format with the duration formatter ("45 s", "3 min 20 s", "1 h 5 min").
    func elapsedSeconds(now: Date = Date()) -> TimeInterval? {
        startedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// The job panel's Cancel button (jobpanel.js:132-133): "Cancel requested" once requested too late,
    /// "Cancelling…" once requested, else "Cancel". Disabled once `cancelRequested`.
    var cancelButtonTitle: String {
        guard cancelRequested else { return "Cancel" }
        return isTooLateToCancel ? "Cancel requested" : "Cancelling…"
    }

    /// What Cancel asks first (`cancelQuestion`, jobpanel.js:22-38; 03 §7.5). Confirming still sends the
    /// cancel, also when it is too late.
    var cancelQuestion: ConfirmationText {
        guard isTooLateToCancel else {
            if kind == .live {
                // docs/LIVE.md: a cancel stops the live analysis at once; the stats so far and the film stay.
                return ConfirmationText(
                    title: "Stop the live analysis now?",
                    message: "The game stops taking film. The stats so far are kept, and the film that has arrived is put together.\n\n"
                        + "To let the parts already sent finish first, use End live game instead.")
            }
            return ConfirmationText(title: "Stop this job? You can start it again later.")
        }
        if kind == .report {
            return ConfirmationText(
                title: "Too late to cancel: Claude is already writing the scouting report.",
                message: "It will finish on its own, and the report is kept.")
        }
        if stage == .reporting {
            return ConfirmationText(
                title: "Too late to cancel: the analysis is finished and Claude is already writing the scouting report.",
                message: "The job will finish on its own, and the report is kept.")
        }
        if kind == .reanalyze {
            return ConfirmationText(
                title: "Too late to stop the re-analysis: it is already redoing the stats (about a minute), so it will finish.",
                message: writesReportAfterwards
                    ? "Cancelling now only skips the automatic scouting report."
                    : "There is nothing left to cancel.")
        }
        return ConfirmationText(
            title: "Too late to stop the analysis: the new GPU results are already in place, so it will finish.",
            message: "Cancelling now only skips the automatic scouting report, if one was going to be written.")
    }

    /// Failed after the GPU results were installed (`failedPastTheGpu`, game.js:49): the server retries such an
    /// ANALYZE as a REANALYZE.
    var failedPastTheGPU: Bool {
        status == .failed && (stage == .analyzing || stage == .reporting)
    }

    /// Start again / Retry of this job sends the film to the GPU again (`retriedOnTheGpu`, game.js:58).
    /// Confirm first when the game `has_tracking` (03 §7.5, 09 D1 #5). A live job's retry analyses the film
    /// that was put together as a whole (docs/LIVE.md), which is a GPU run too.
    var retriesOnTheGPU: Bool { (kind == .analyze && !failedPastTheGPU) || kind == .live }

    /// Start again / Retry needs the Full re-analysis confirmation (03 §7.5): the game has GPU results and
    /// this retry would send the film to the GPU again.
    func retryNeedsConfirmation(gameHasTracking: Bool) -> Bool {
        gameHasTracking && retriesOnTheGPU
    }

    /// The finished job panel's action (jobpanel.js:175-200; 03 §7.5): cancelled → Start again; failed →
    /// Re-run analysis for an ANALYZE at `analyzing`/`reporting` (even when not retryable), else Retry unless
    /// `error.retryable` is false (a missing error counts as retryable), else none. Nil for active and
    /// succeeded jobs. (A job the queue refused has stage `done`, so it gets Retry; 09 B4.)
    var finishedAction: FinishedJobAction? {
        switch status {
        case .queued, .running, .succeeded: return nil
        case .cancelled: return .startAgain
        default:
            if kind == .analyze && (stage == .analyzing || stage == .reporting) { return .rerunAnalysis }
            return error?.retryable == false ? nil : .retry
        }
    }

    /// The error box of a failed job (jobpanel.js:197): `error`, or "<kind label> failed" with `message`
    /// (or "The job stopped with an error.").
    var failureInfo: ErrorInfo {
        error ?? ErrorInfo(
            code: ErrorCode.jobFailed,
            title: "\(kind.label) failed",
            message: message.isEmpty ? "The job stopped with an error." : message,
            retryable: true)
    }

    /// The succeeded-with-warnings notice title (jobpanel.js:177): "<kind label> finished with warnings".
    var finishedWithWarningsTitle: String { "\(kind.label) finished with warnings" }

    /// The cancelled notice (jobpanel.js:184-188): "<kind label> was cancelled" / "Start it again whenever
    /// you are ready." A cancelled live job cannot take the stream up again: starting it again analyses the
    /// film that arrived (docs/LIVE.md).
    var cancelledNotice: NoticeText {
        NoticeText(
            tone: .info, title: "\(kind.label) was cancelled",
            message: kind == .live ? Self.liveCancelledMessage : "Start it again whenever you are ready.")
    }

    /// Under "Live analysis was cancelled".
    static let liveCancelledMessage = "The stats so far are kept. Start again analyses the film that arrived."
    /// Under "Live analysis was cancelled" when no film had arrived: there is nothing to start again.
    static let liveCancelledWithoutFilmMessage = "No film had arrived. You can start the live stream again from Add film."

    /// The finished job panel is shown (03 §7.3 row 3): active, failed, cancelled, or succeeded with warnings.
    var showsPanel: Bool {
        status != .succeeded || !warnings.isEmpty
    }

    /// The game page header badge while this analysis job is active (game.js:271-283): running →
    /// "Processing · NN%" (or "Processing" at 0%), queued → "Queued"; nil when the job is not active.
    var gameHeaderBadge: BadgeLabel? {
        switch status {
        case .running:
            let text = progressPercent != 0 ? "\(GameStatus.processing.badgeText) · \(progressPercent)%" : GameStatus.processing.badgeText
            return BadgeLabel(text, tone: GameStatus.processing.badgeTone)
        case .queued:
            return GameStatus.queued.badge
        default:
            return nil
        }
    }

    /// `params.coach_focus` (report jobs; stored untrimmed when posted, 09 C1).
    var coachFocus: String? { params["coach_focus"]?.stringValue }

    /// `params.report` is truthy: a REANALYZE writes a scouting report afterwards (jobpanel.js:33).
    var writesReportAfterwards: Bool { params["report"]?.isTruthy ?? false }

    /// `lease_expires_at` as a date (internal to the server).
    var leaseExpiresDate: Date? { leaseExpiresAt.map { Date(timeIntervalSince1970: $0) } }
}

/// The button a finished job's panel offers (03 §7.5).
nonisolated enum FinishedJobAction: Hashable, Sendable {
    /// "Start again" for a cancelled job (`POST /api/jobs/{id}/retry`).
    case startAgain
    /// "Retry" for a failed job.
    case retry
    /// "Re-run analysis" for an ANALYZE that failed after its GPU results were installed (the server retries
    /// it as a REANALYZE).
    case rerunAnalysis

    /// "Start again" / "Retry" / "Re-run analysis"; busy label "Starting…".
    var title: String {
        switch self {
        case .startAgain: "Start again"
        case .retry: "Retry"
        case .rerunAnalysis: "Re-run analysis"
        }
    }
}

nonisolated extension Sequence where Element == Job {
    /// The job panel's job: the first (newest) job whose kind is not `report`, in any status (game.js:80-84).
    /// Take it from the jobs list, not from `latest_job_id` (09 R33).
    var latestAnalysisJob: Job? { first { $0.kind != .report } }

    /// The report job to resume following: the first `report` job that is active (game.js:84).
    var activeReportJob: Job? { first { $0.kind == .report && $0.isActive } }
}
