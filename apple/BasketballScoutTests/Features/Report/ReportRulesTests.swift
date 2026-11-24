import Foundation
import Testing
@testable import BasketballScout

/// The report tab's rules (03 §5.1, §7.8; 09 R30, C10, B13).
@MainActor
struct ReportRulesTests {
    private static let gameID = "g_e934f8c21058"

    private static func report(_ id: String, at time: String?, focus: String? = nil) throws -> ReportRecord {
        var record = try #require(try Fixture.decode([ReportRecord].self, "reports_list_seeded.json").first)
        record.id = id
        record.createdAt = time.flatMap(ScoutTimestamp.date(from:))
        record.coachFocus = focus
        return record
    }

    private static func reportJob(
        _ status: JobStatus = .succeeded, stage: JobStage = .done, startedAt: String? = "2026-11-11T20:10:00Z",
        cancelRequested: Bool = false, error: ErrorInfo? = nil, warnings: [String] = []
    ) -> Job {
        Job(
            id: "j_22acdd6ecdcf", gameID: gameID, kind: .report, status: status, stage: stage, error: error,
            warnings: warnings, cancelRequested: cancelRequested,
            startedAt: startedAt.flatMap(ScoutTimestamp.date(from:)))
    }

    // MARK: Order and selection (09 R30, C10)

    @Test func reportsAreSortedNewestFirstByTheirParsedDates() throws {
        let older = try Self.report("r_1", at: "2026-11-10T09:00:00Z")
        let newer = try Self.report("r_2", at: "2026-11-11T20:03:51.065936Z")
        let undated = try Self.report("r_3", at: nil)
        let sorted = ReportRules.newestFirst([older, undated, newer])
        #expect(sorted.map(\.id) == ["r_2", "r_1", "r_3"])
    }

    @Test func equalDatesKeepTheServersOrder() throws {
        let a = try Self.report("r_a", at: "2026-11-11T10:00:00Z")
        let b = try Self.report("r_b", at: "2026-11-11T10:00:00Z")
        #expect(ReportRules.newestFirst([a, b]).map(\.id) == ["r_a", "r_b"])
        #expect(ReportRules.newestFirst([b, a]).map(\.id) == ["r_b", "r_a"])
    }

    @Test func theReportAJobWroteIsTheNewestWrittenAfterItStarted() throws {
        let before = try Self.report("r_before", at: "2026-11-11T20:00:00Z")
        let after = try Self.report("r_after", at: "2026-11-11T20:11:00Z")
        let job = Self.reportJob(startedAt: "2026-11-11T20:10:00Z")
        #expect(ReportRules.reportWritten(by: job, in: [after, before])?.id == "r_after")
        #expect(ReportRules.reportWritten(by: job, in: [before, after])?.id == "r_after")
    }

    @Test func withoutAReportAfterTheStartTheNewestIsTaken() throws {
        let older = try Self.report("r_older", at: "2026-11-11T19:00:00Z")
        let newer = try Self.report("r_newer", at: "2026-11-11T20:00:00Z")
        #expect(ReportRules.reportWritten(by: Self.reportJob(startedAt: "2026-11-11T21:00:00Z"), in: [older, newer])?.id == "r_newer")
        #expect(ReportRules.reportWritten(by: Self.reportJob(startedAt: nil), in: [older, newer])?.id == "r_newer")
        #expect(ReportRules.reportWritten(by: Self.reportJob(), in: []) == nil)
    }

    @Test func thePickedVersionWinsWhileItExists() throws {
        let older = try Self.report("r_older", at: "2026-11-11T19:00:00Z")
        let newer = try Self.report("r_newer", at: "2026-11-11T20:00:00Z")
        #expect(ReportRules.selectedReport(in: [newer, older], pinnedID: "r_older", finishedJob: nil)?.id == "r_older")
        #expect(ReportRules.selectedReport(in: [newer, older], pinnedID: "r_gone", finishedJob: nil)?.id == "r_newer")
        #expect(ReportRules.selectedReport(in: [newer, older], pinnedID: nil, finishedJob: nil)?.id == "r_newer")
        #expect(ReportRules.selectedReport(in: [], pinnedID: "r_older", finishedJob: nil) == nil)
    }

    @Test func afterASucceededReportJobItsReportIsShown() throws {
        let written = try Self.report("r_written", at: "2026-11-11T20:11:00Z")
        let other = try Self.report("r_other", at: "2026-11-11T20:00:00Z")
        let job = Self.reportJob(startedAt: "2026-11-11T20:10:00Z")
        #expect(ReportRules.selectedReport(in: [written, other], pinnedID: nil, finishedJob: job)?.id == "r_written")
        // A failed job does not choose.
        let failed = Self.reportJob(.failed, stage: .reporting)
        #expect(ReportRules.selectedReport(in: [other, written], pinnedID: nil, finishedJob: failed)?.id == "r_written")
    }

    // MARK: Version picker (report.js:96-101, 07 §5.4)

    @Test func versionTitlesNameTheTimeTheModelAndTheCoachFocus() throws {
        let locale = Locale(identifier: "en_US")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let withFocus = try Self.report("r_1", at: "2026-11-11T20:03:51.065936Z", focus: "We play a 2-3 zone")
        let when = ScoutFormat.dateTime(withFocus.createdAt, locale: locale, timeZone: utc)
        #expect(!when.isEmpty)
        #expect(ReportRules.versionTitle(withFocus, locale: locale, timeZone: utc) == "\(when) · claude-opus-5-5 · with coach focus")

        let withoutFocus = try Self.report("r_2", at: "2026-11-11T20:03:51.065936Z", focus: nil)
        #expect(ReportRules.versionTitle(withoutFocus, locale: locale, timeZone: utc) == "\(when) · claude-opus-5-5")
        let blankFocus = try Self.report("r_3", at: "2026-11-11T20:03:51.065936Z", focus: "  ")
        #expect(ReportRules.versionTitle(blankFocus, locale: locale, timeZone: utc) == "\(when) · claude-opus-5-5")
        let undated = try Self.report("r_4", at: nil)
        #expect(ReportRules.versionTitle(undated, locale: locale, timeZone: utc) == "claude-opus-5-5")
    }

    @Test func theVersionPickerShowsWithOneReportAndWorksWithTwo() {
        #expect(!ReportRules.showsVersionPicker(reportCount: 0))
        #expect(ReportRules.showsVersionPicker(reportCount: 1))
        #expect(!ReportRules.versionPickerEnabled(reportCount: 1))
        #expect(ReportRules.versionPickerEnabled(reportCount: 2))
    }

    // MARK: Generating (03 §7.8)

    @Test func theGenerateButtonSaysRegenerateOnceThereIsAReport() {
        #expect(ReportRules.generateTitle(hasReports: false) == "Generate report")
        #expect(ReportRules.generateTitle(hasReports: true) == "Regenerate report")
    }

    @Test func theStatusLineFollowsTheWeb() {
        let queued = Self.reportJob(.queued, stage: .queued, startedAt: nil)
        #expect(ReportRules.statusLine(for: queued) == "Waiting for the background worker\u{2026} This usually takes one to three minutes.")

        let writing = Self.reportJob(.running, stage: .reporting)
        #expect(ReportRules.statusLine(for: writing) == "Writing scouting report\u{2026} This usually takes one to three minutes.")

        // A report job past `queued` always says "Writing scouting report" (labels.js:147-156).
        let starting = Self.reportJob(.running, stage: .preparing)
        #expect(ReportRules.statusLine(for: starting).hasPrefix("Writing scouting report\u{2026}"))

        let lateCancel = Self.reportJob(.running, stage: .reporting, cancelRequested: true)
        #expect(ReportRules.statusLine(for: lateCancel)
            == "Writing scouting report\u{2026} Cancel requested: Claude is already writing it, so it will finish and be kept.")

        let cancelling = Self.reportJob(.running, stage: .queued, cancelRequested: true)
        #expect(ReportRules.statusLine(for: cancelling) == "Cancelling\u{2026}")
    }

    @Test func theCoachFocusIsCutToTheServersLimit() {
        #expect(ReportRules.clampedFocus("We play a 2-3 zone") == "We play a 2-3 zone")
        let long = String(repeating: "a", count: 2100)
        #expect(ReportRules.clampedFocus(long).count == 2000)
        // A flag is two code points: it is never split at the limit.
        let edge = String(repeating: "a", count: 1999) + "🇺🇸" + "b"
        let clamped = ReportRules.clampedFocus(edge)
        #expect(clamped == String(repeating: "a", count: 1999))
        #expect(ReportRules.focusLength(clamped) <= ReportRequest.maximumFocusLength)
        let exact = String(repeating: "a", count: 1998) + "🇺🇸"
        #expect(ReportRules.clampedFocus(exact) == exact)
    }

    // MARK: The report area's one box (07 §5.1; 09 B13)

    @Test func aFailedStartIsShownBeforeAnythingElse() throws {
        let start = DisplayError(title: "Conflict", message: "A scouting report is already being written for this game.")
        let polling = DisplayError(title: "Can't reach the server", message: "…", isRetryable: true)
        let notice = ReportRules.notice(
            actionError: start, trackingError: polling, reportsError: nil,
            finishedJob: Self.reportJob(.cancelled), hiddenJobID: nil)
        guard case .actionFailed(let error)? = notice else { Issue.record("expected the start error"); return }
        #expect(error.title == "Conflict")
    }

    @Test func pollingThatGaveUpComesNextThenTheList() {
        let polling = DisplayError(title: "Can't reach the server", message: "…", isRetryable: true)
        let list = DisplayError(title: "Server unavailable", message: "…", isRetryable: true)
        guard case .trackingFailed? = ReportRules.notice(
            actionError: nil, trackingError: polling, reportsError: list, finishedJob: nil, hiddenJobID: nil)
        else { Issue.record("expected the polling error"); return }
        guard case .reportsFailed(let error)? = ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: list, finishedJob: Self.reportJob(.cancelled), hiddenJobID: nil)
        else { Issue.record("expected the list error"); return }
        #expect(error.title == "Server unavailable")
    }

    @Test func aFailedJobShowsItsErrorWithTryAgainWhenRetryable() throws {
        let rateLimited = ErrorInfo(
            code: ErrorCode.reportRateLimited, title: "Claude rate limit reached",
            message: "The Anthropic API is rate limiting this key.",
            hint: "Wait a minute and click 'Generate report' again.", retryable: true)
        let notice = ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil,
            finishedJob: Self.reportJob(.failed, stage: .reporting, error: rateLimited), hiddenJobID: nil)
        guard case .jobFailed(let error)? = notice else { Issue.record("expected the job error"); return }
        #expect(error.title == "Claude rate limit reached")
        #expect(error.hint == "Wait a minute and click 'Generate report' again.")
        #expect(error.isRetryable)
    }

    @Test func aFailedJobWithoutAnErrorUsesTheWebsFallbackWithoutTryAgain() {
        let notice = ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil,
            finishedJob: Self.reportJob(.failed, stage: .queued), hiddenJobID: nil)
        guard case .jobFailed(let error)? = notice else { Issue.record("expected the fallback"); return }
        #expect(error.title == "Report failed")
        #expect(error.message == "The report could not be written.")
        #expect(!error.isRetryable)
    }

    @Test func cancelledAndWarningOutcomes() {
        guard case .jobCancelled? = ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil, finishedJob: Self.reportJob(.cancelled), hiddenJobID: nil)
        else { Issue.record("expected the cancelled notice"); return }
        #expect(ReportTexts.cancelledMessage == "Report generation was cancelled.")

        let kept = Self.reportJob(warnings: ["Cancelled after Claude had started writing the report: the report was kept."])
        guard case .jobFinishedWithWarnings(let title, let warnings)? = ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil, finishedJob: kept, hiddenJobID: nil)
        else { Issue.record("expected the warnings"); return }
        #expect(title == "Scouting report finished with warnings")
        #expect(warnings.count == 1)

        #expect(ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil, finishedJob: Self.reportJob(), hiddenJobID: nil) == nil)
    }

    @Test func anOutcomeTheCoachMovedPastIsHidden() {
        let job = Self.reportJob(.cancelled)
        #expect(ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil, finishedJob: job, hiddenJobID: job.id) == nil)
        var analysis = job
        analysis.kind = .analyze
        #expect(ReportRules.notice(
            actionError: nil, trackingError: nil, reportsError: nil, finishedJob: analysis, hiddenJobID: nil) == nil)
    }
}
