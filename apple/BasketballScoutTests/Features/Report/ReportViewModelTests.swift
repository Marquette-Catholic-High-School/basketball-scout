import Foundation
import Testing
@testable import BasketballScout

/// Starting, following, cancelling and showing scouting reports against a stubbed server (03 §5.1, §7.8;
/// 09 C1–C3, R30, R31, R36, D1 #3).
@MainActor
struct ReportViewModelTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }

    /// A signed-in harness whose server knows the ready game of the fixtures (one seeded report).
    private func readyServer() async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        h.server.on("GET", gamePath, .fixture("game_ready.json"))
        h.server.on("GET", "\(gamePath)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list.json"))
        h.server.on("GET", "\(gamePath)/reports", .fixture("reports_list_seeded.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        return h
    }

    private func context(_ h: SessionHarness) -> GameContext {
        GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "ReportViewModelTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
    }

    private func reportJob(
        _ id: String = "j_22acdd6ecdcf", status: JobStatus, stage: JobStage, cancelRequested: Bool = false,
        startedAt: String? = "2026-11-11T20:24:43Z", updatedAt: String = "2026-11-11T20:24:43Z"
    ) -> Job {
        Job(
            id: id, gameID: gameID, kind: .report, status: status, stage: stage,
            progress: status == .succeeded ? 100 : 10, message: "", params: ["coach_focus": .null],
            cancelRequested: cancelRequested, createdAt: ScoutTimestamp.date(from: "2026-11-11T20:24:42.030060Z"),
            startedAt: startedAt.flatMap(ScoutTimestamp.date(from:)), updatedAt: ScoutTimestamp.date(from: updatedAt))
    }

    /// The seeded report plus a newer one written by the report job.
    private func reportsAfterTheJob() throws -> [ReportRecord] {
        let seeded = try Fixture.decode([ReportRecord].self, "reports_list_seeded.json")
        var written = try #require(seeded.first)
        written.id = "r_0123456789ab"
        written.createdAt = ScoutTimestamp.date(from: "2026-11-11T20:26:10Z")
        written.coachFocus = "We play a 2-3 zone"
        return [written] + seeded
    }

    /// The seeded report and an older version.
    private func twoVersions() throws -> [ReportRecord] {
        let seeded = try Fixture.decode([ReportRecord].self, "reports_list_seeded.json")
        var older = try #require(seeded.first)
        older.id = "r_00000000000a"
        older.createdAt = ScoutTimestamp.date(from: "2026-11-10T18:00:00Z")
        older.coachFocus = nil
        return seeded + [older]
    }

    // MARK: Generating (03 §5.1)

    @Test func generateSendsTheTrimmedFocusFollowsTheJobAndShowsItsReport() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/reports", try SessionFixtures.reply(try twoVersions()))
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        #expect(context.reports.count == 2)

        h.server.on("POST", "\(gamePath)/reports", try SessionFixtures.reply(reportJob(status: .queued, stage: .queued, startedAt: nil), status: 202))
        h.server.on(
            "GET", "/api/jobs/j_22acdd6ecdcf",
            try SessionFixtures.reply(reportJob(status: .running, stage: .reporting, updatedAt: "2026-11-11T20:24:50Z")),
            try SessionFixtures.reply(reportJob(status: .succeeded, stage: .done, updatedAt: "2026-11-11T20:26:11Z")))
        h.server.on("GET", "\(gamePath)/reports", try SessionFixtures.reply(try reportsAfterTheJob() + [try twoVersions()[1]]))

        // An older version was picked: the new report replaces it on screen after the job.
        model.select("r_00000000000a", in: context)
        #expect(model.selectedReport(in: context)?.id == "r_00000000000a")
        model.setFocus("  We play a 2-3 zone \n")
        await model.generate(in: context)

        let post = try #require(h.server.requests.last { $0.method == "POST" })
        #expect(post.path == "\(gamePath)/reports")
        #expect(post.bodyText == #"{"coach_focus":"We play a 2-3 zone"}"#)
        #expect(post.header("Content-Type") == "application/json")
        #expect(post.header("Authorization") != nil)
        #expect(model.isFollowingJob(in: context))
        #expect(!model.canGenerate(in: context))
        #expect(model.focusText == "  We play a 2-3 zone \n", "the focus is not cleared (03 §7.8)")

        try await waitUntil("the report job ended and the reports were reloaded") {
            context.finishedReportJob?.status == .succeeded && context.reports.count == 3
        }
        model.sync(with: context)
        #expect(model.selectedReport(in: context)?.id == "r_0123456789ab")
        #expect(model.pinnedReportID == nil)
        #expect(model.notice(in: context) == nil)
        #expect(model.canGenerate(in: context))
    }

    @Test func anEmptyFocusIsSentAsNull() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        h.server.on("POST", "\(gamePath)/reports", try SessionFixtures.reply(reportJob(status: .succeeded, stage: .done), status: 202))
        model.setFocus("   \n ")
        await model.generate(in: context)
        let post = try #require(h.server.requests.last { $0.method == "POST" })
        #expect(post.bodyText == #"{"coach_focus":null}"#)
    }

    @Test func aRefusedStartIsShownAndThePageIsReadAgain() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        h.server.on("POST", "\(gamePath)/reports", .fixture("err_409_report_while_analyzing.json", status: 409))
        let gameLoads = h.server.count("GET", gamePath)

        await model.generate(in: context)

        #expect(model.actionError?.title == "Conflict")
        #expect(model.actionError?.message == "This game's film is being analysed right now.")
        #expect(h.server.count("GET", gamePath) == gameLoads + 1, "09 R36: re-read the page after a refused start")
        guard case .actionFailed? = model.notice(in: context) else {
            Issue.record("the refused start shows in the report area")
            return
        }
        #expect(!model.isStarting)
        #expect(model.canGenerate(in: context))
    }

    @Test func aServerWithoutAnAnthropicKeyIsExplained() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        h.server.on("POST", "\(gamePath)/reports", .fixture("err_503_report_not_configured.json", status: 503))
        await model.generate(in: context)
        #expect(model.actionError?.title == "Claude is not configured")
        #expect(model.actionError?.hint == "Add ANTHROPIC_API_KEY to .env and restart the worker.")
    }

    @Test func aRejectedPasswordGoesToTheLockoutGateAndShowsNothingHere() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        h.server.on("POST", "\(gamePath)/reports", .fixture("err_401_wrong_password.json", status: 401))
        await model.generate(in: context)
        #expect(model.actionError == nil)
        guard case .needsPassword = h.session.state else {
            Issue.record("a 401 must return to sign-in (09 R6)")
            return
        }
    }

    @Test func generatingAgainHidesTheLastOutcome() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        h.server.on("POST", "\(gamePath)/reports", try SessionFixtures.reply(reportJob(status: .queued, stage: .queued, startedAt: nil), status: 202))
        h.server.on("GET", "/api/jobs/j_22acdd6ecdcf", try SessionFixtures.reply(reportJob(status: .cancelled, stage: .done)))
        await model.generate(in: context)
        try await waitUntil("the report job ended") { context.finishedReportJob?.status == .cancelled }
        guard case .jobCancelled? = model.notice(in: context) else {
            Issue.record("expected \"Report generation was cancelled.\"")
            return
        }
        h.server.on("POST", "\(gamePath)/reports", .fixture("err_409_report_while_analyzing.json", status: 409))
        await model.generate(in: context)
        guard case .actionFailed? = model.notice(in: context) else {
            Issue.record("the new problem replaces the old outcome (boxes never stack)")
            return
        }
        model.clearActionError()
        #expect(model.notice(in: context) == nil, "the cancelled outcome stays hidden after generating again")
    }

    // MARK: Cancelling (09 R31)

    @Test func cancelSendsTheCancelAndShowsTheOutcome() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        let cancelled = reportJob(status: .cancelled, stage: .done, cancelRequested: true, updatedAt: "2026-11-11T20:25:00Z")
        let held = HeldReply { (try? SessionFixtures.reply(cancelled)) ?? .empty(500) }
        h.server.on("GET", "/api/jobs/j_22acdd6ecdcf", .held(held))
        h.server.on("POST", "/api/jobs/j_22acdd6ecdcf/cancel", try SessionFixtures.reply(cancelled))
        context.track(job: reportJob(status: .queued, stage: .queued, startedAt: nil))
        try await waitUntil("the report job is being followed") { held.isWaiting }
        #expect(model.followedJob(in: context)?.cancelButtonTitle == "Cancel")
        #expect(model.followedJob(in: context)?.cancelQuestion.title == "Stop this job? You can start it again later.")
        let gameLoads = h.server.count("GET", gamePath)

        await model.cancel(in: context)

        #expect(h.server.count("POST", "/api/jobs/j_22acdd6ecdcf/cancel") == 1)
        #expect(context.finishedReportJob?.status == .cancelled)
        #expect(model.followedJob(in: context) == nil)
        guard case .jobCancelled? = model.notice(in: context) else {
            Issue.record("expected \"Report generation was cancelled.\"")
            return
        }
        // The cancel's answer ended the job: its poller is stopped too, so the page reloads once, not twice.
        try await waitUntil("the poll to be cancelled") { held.isCancelled }
        held.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.server.count("GET", gamePath) == gameLoads + 1)
    }

    @Test func aTooLateCancelKeepsTheReportAndSaysSo() {
        let writing = reportJob(status: .running, stage: .reporting)
        #expect(writing.isTooLateToCancel)
        #expect(writing.cancelQuestion.title == "Too late to cancel: Claude is already writing the scouting report.")
        #expect(writing.cancelQuestion.message == "It will finish on its own, and the report is kept.")
        let requested = reportJob(status: .running, stage: .reporting, cancelRequested: true)
        #expect(requested.cancelButtonTitle == "Cancel requested")
    }

    // MARK: Download .md (03 §2.3)

    @Test func downloadMarkdownAsksForTheVersionOnScreen() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/report.md", .http(
            status: 200,
            headers: [
                "Content-Type": "text/markdown; charset=utf-8",
                "Content-Disposition": "attachment; filename=\"scouting_report_test-team-a_2026-11-07.md\"",
            ],
            pieces: [try Fixture.data("export_report_md.md")]))
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        let record = try #require(model.selectedReport(in: context))
        model.files.appeared()

        await model.downloadMarkdown(record, in: context)

        #expect(h.server.requests.last { $0.path.hasSuffix("/report.md") }?.query == "report_id=\(record.id)&download=1")
        let file = try #require(model.files.readyFile)
        #expect(file.filename == "scouting_report_test-team-a_2026-11-07.md")
        #expect(try Data(contentsOf: file.url) == (try Fixture.data("export_report_md.md")))
        #expect(model.actionError == nil)
        model.files.disappeared()
        #expect(model.files.readyFile == nil)
    }

    @Test func aMissingReportFileIsExplained() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/export/report.md", .fixture("err_404_report_md_wrong_id.json", status: 404))
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        model.files.appeared()
        await model.downloadMarkdown(try #require(model.selectedReport(in: context)), in: context)
        #expect(model.actionError?.title == "Not found")
        #expect(model.files.readyFile == nil)
        model.files.disappeared()
    }

    // MARK: Versions and focus

    @Test func pickingTheNewestFollowsTheNewestAgain() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/reports", try SessionFixtures.reply(try reportsAfterTheJob()))
        let context = context(h)
        let model = ReportViewModel()
        await context.refresh()
        let reports = model.reports(in: context)
        #expect(reports.map(\.id) == ["r_0123456789ab", "r_cb24d96d31d7"])
        #expect(model.selectedReport(in: context)?.id == "r_0123456789ab")
        model.select("r_cb24d96d31d7", in: context)
        #expect(model.selectedReport(in: context)?.id == "r_cb24d96d31d7")
        #expect(model.pinnedReportID == "r_cb24d96d31d7")
        model.select("r_0123456789ab", in: context)
        #expect(model.pinnedReportID == nil)
    }

    @Test func theFocusIsCutTo2000Characters() {
        let model = ReportViewModel()
        model.setFocus(String(repeating: "z", count: 2500))
        #expect(model.focusText.count == ReportRequest.maximumFocusLength)
    }

    // MARK: Page models (ReportPageModels)

    @Test func eachPageKeepsItsModelsAndSignOutClearsThem() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let first = context(h)
        let second = context(h)
        let model = ReportPageModels.report(for: first)
        #expect(ReportPageModels.report(for: first) === model)
        #expect(ReportPageModels.exports(for: first) === ReportPageModels.exports(for: first))
        #expect(ReportPageModels.report(for: second) !== model)
        model.setFocus("We play a 2-3 zone")
        model.select("r_cb24d96d31d7", in: first)

        h.session.signOut()

        #expect(model.focusText.isEmpty, "the session stopped: nothing the coach typed is kept")
        #expect(model.pinnedReportID == nil)
    }
}
