import Foundation
import Observation

/// The scouting report tab (03 §5.1, §7.8; 09 C1–C3, C10, R30, R31). One per game page
/// (`ReportPageModels`), so the coach focus and the chosen version survive tab switches.
///
/// The page's `GameContext` loads the reports (every refresh with an analysis) and follows the report job
/// (`JobPoller`, every 3 s while the page is visible, toast "Scouting report ready", page reload when it
/// ends). This model starts the job (`POST …/reports` with the trimmed focus), cancels it (09 R31),
/// chooses the report to show (09 R30) and keeps the one message box of the report area.
@Observable
final class ReportViewModel: SessionActivity {
    /// The coach focus text; kept after generating, as on the web (03 §7.8). Set it with `setFocus(_:)`.
    private(set) var focusText = ""
    /// "Report on": the team the next report is about and whose reports show. Set it with `setSide(_:)`.
    private(set) var side: TeamSide = .scouted
    /// The version the coach picked; nil follows the newest report on `side`.
    private(set) var pinnedReportID: String?
    /// Starting or cancelling the report job failed (already through the lockout gate).
    private(set) var actionError: (any PresentableError)?
    /// `POST …/reports` is on its way.
    private(set) var isStarting = false
    /// `POST /api/jobs/{id}/cancel` is on its way.
    private(set) var isCancelling = false
    /// The finished job whose outcome the coach has moved past by generating again.
    private(set) var hiddenOutcomeJobID: String?
    /// The Markdown download ("Download .md").
    let files = ReportFileHandoff()

    @ObservationIgnored private var lastFinishedJobID: String?

    // MARK: - What the tab shows

    /// The reports, newest first.
    func reports(in context: GameContext) -> [ReportRecord] {
        ReportRules.newestFirst(context.reports)
    }

    /// The report on screen (09 R30 after a report job succeeded).
    func selectedReport(in context: GameContext) -> ReportRecord? {
        ReportRules.selectedReport(
            in: context.reports, side: side, pinnedID: pinnedReportID, finishedJob: context.finishedReportJob)
    }

    /// There is a report on the chosen team ("Regenerate report").
    func hasReport(in context: GameContext) -> Bool {
        ReportRules.newest(on: side, in: context.reports) != nil
    }

    /// A report job is being followed (Generate is disabled and the status line shows). After following
    /// gave up, Generate is enabled again, as on the web (09 C10).
    func isFollowingJob(in context: GameContext) -> Bool {
        context.activeReportJob != nil && context.reportTrackingError == nil
    }

    /// The job whose progress the status line shows.
    func followedJob(in context: GameContext) -> Job? {
        isFollowingJob(in: context) ? context.activeReportJob : nil
    }

    /// Generate is enabled: signed in, nothing starting, no report job followed (03 §7.8).
    func canGenerate(in context: GameContext) -> Bool {
        context.client != nil && !isStarting && !isFollowingJob(in: context)
    }

    /// The report area's one box.
    func notice(in context: GameContext) -> ReportNotice? {
        ReportRules.notice(
            actionError: actionError,
            trackingError: context.reportTrackingError,
            reportsError: context.reportsError,
            finishedJob: context.finishedReportJob,
            hiddenJobID: hiddenOutcomeJobID)
    }

    // MARK: - Actions

    /// Changes the focus text, cut to the server's 2000 characters.
    func setFocus(_ text: String) {
        let clamped = ReportRules.clampedFocus(text)
        if clamped != focusText { focusText = clamped }
    }

    /// "Report on": shows that team's newest report; Generate writes about it.
    func setSide(_ newSide: TeamSide) {
        guard newSide != side else { return }
        side = newSide
        pinnedReportID = nil
    }

    /// Picks a version, and "Report on" moves to its team (Regenerate writes about the team on show);
    /// picking that team's newest follows the newest again.
    func select(_ reportID: String, in context: GameContext) {
        guard let record = context.reports.first(where: { $0.id == reportID }) else { return }
        side = record.reportSide
        pinnedReportID = ReportRules.newest(on: side, in: context.reports)?.id == reportID ? nil : reportID
    }

    /// Takes in a report job that ended since the last look: after a success the new report is shown
    /// (the web selects the newest after reloading the list).
    func sync(with context: GameContext) {
        guard let job = context.finishedReportJob, job.id != lastFinishedJobID else { return }
        lastFinishedJobID = job.id
        if job.status == .succeeded { pinnedReportID = nil }
    }

    /// "Generate report" / "Regenerate report" / "Try again" (03 §5.1): `POST …/reports` with the trimmed
    /// focus (null when empty, 09 D1 #3), then follow the job. A refused start (409 CONFLICT while an
    /// analysis runs or another report is being written, 409 ANALYSIS_NOT_READY, 503 REPORT_NOT_CONFIGURED)
    /// shows in the report area and re-reads the page (09 R36), which also picks up a report job another
    /// device started.
    func generate(in context: GameContext) async {
        guard !isStarting, let client = context.client else { return }
        isStarting = true
        actionError = nil
        hiddenOutcomeJobID = context.finishedReportJob?.id
        let request = ReportRequest(coachFocus: focusText, side: side)
        do {
            let job = try await client.generateReport(gameID: context.gameID, request)
            isStarting = false
            context.track(job: job)
        } catch {
            isStarting = false
            guard let shown = context.session.report(error, from: client) else { return }
            actionError = shown
            await context.refresh()
        }
    }

    /// Cancels the followed report job (09 R31; confirm first with `job.cancelQuestion`). Queued: it stops at
    /// once; while Claude writes: too late, it finishes and the report is kept.
    func cancel(in context: GameContext) async {
        guard !isCancelling, let job = context.activeReportJob, let client = context.client else { return }
        isCancelling = true
        defer { isCancelling = false }
        actionError = nil
        do {
            try await context.cancelJob(job)
        } catch {
            if let shown = context.session.report(error, from: client) { actionError = shown }
        }
    }

    /// "Download .md": the server's Markdown of `record`, re-rendered with the current game details.
    func downloadMarkdown(_ record: ReportRecord, in context: GameContext) async {
        actionError = nil
        let gameID = context.gameID
        let reportID = record.id
        if let error = await files.download(.reportMarkdown, in: context, { client in
            try await client.downloadReportMarkdown(gameID: gameID, reportID: reportID)
        }) {
            actionError = error
        }
    }

    /// Shows a local problem (printing, saving) in the report area.
    func show(_ error: any PresentableError) {
        actionError = error
    }

    /// Prints `record` (the tab's Print button and File > Print… ⌘P): the system print UI with the report's
    /// HTML; a problem shows in the tab's message box.
    func print(_ record: ReportRecord, gameTitle: String) {
        let html = ReportHTML.document(record, gameTitle: gameTitle)
        if let error = ReportPrinter.print(html: html, jobName: ReportTexts.heading(gameTitle: gameTitle)) {
            show(error)
        }
    }

    /// The coach closed the box.
    func clearActionError() {
        actionError = nil
    }

    // MARK: - SessionActivity

    /// The lockout gate or sign-out stopped everything: forget the focus text and the file.
    func sessionDidStop() {
        focusText = ""
        side = .scouted
        pinnedReportID = nil
        actionError = nil
        isStarting = false
        hiddenOutcomeJobID = nil
        files.dismiss()
    }
}
