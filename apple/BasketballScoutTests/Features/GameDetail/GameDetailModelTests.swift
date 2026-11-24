import Foundation
import Testing
@testable import BasketballScout

/// The game page's actions against a stubbed server (03 §7.4–§7.6; 07 §5.2–§5.4; 09 R6, R36): what is sent,
/// what is asked first, the toasts, and where errors show.
@MainActor
struct GameDetailModelTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }
    /// 200 s after the first ANALYZE fixture started.
    private static let now = ScoutTimestamp.date(from: "2026-11-11T20:04:24.134992Z")!

    /// A signed-in harness whose server knows the ready game of the fixtures (teams not confirmed yet).
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

    /// The page's context and model on `h`, with toasts that stay until read.
    private func page(_ h: SessionHarness) -> (context: GameContext, model: GameDetailModel, toasts: ToastCenter) {
        let context = GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "GameDetailModelTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
        let toasts = ToastCenter(sleep: { _ in throw CancellationError() }, announce: { _ in })
        return (context, GameDetailModel(context: context, toasts: toasts, now: { Self.now }), toasts)
    }

    private func actionError(_ model: GameDetailModel) -> (any PresentableError)? {
        if case .action(let error)? = model.pageError { return error }
        return nil
    }

    private func posts(_ h: SessionHarness, _ path: String) -> [RecordedRequest] {
        h.server.requests.filter { $0.method == "POST" && $0.path == path }
    }

    // MARK: - Re-run analysis / Analyze film (03 §7.4)

    @Test func rerunStartsAReanalysisWithoutAskingAndSaysSo() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        #expect(model.actions?.rerunTitle == "Re-run analysis")

        await model.rerun()

        let post = try #require(posts(h, "\(gamePath)/jobs").first)
        #expect(post.bodyText == #"{"kind":"reanalyze"}"#)
        #expect(post.header("Content-Type") == "application/json")
        #expect(model.confirmation == nil)
        #expect(toasts.current?.text == "Re-running the analysis\u{2026}")
        #expect(model.pageError == nil)
        #expect(!model.isWorking)
    }

    @Test func analyzeFilmStartsAnAnalyzeAndSaysAnalysisStarted() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let noTracking = try SessionFixtures.game("game_ready.json") { $0.hasTracking = false }
        h.server.on("GET", gamePath, try SessionFixtures.reply(noTracking))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_analyze_full.json", status: 201))
        let done = try SessionFixtures.job("job_create_analyze_full.json") {
            $0.status = .succeeded
            $0.stage = .done
            $0.progress = 100
        }
        h.server.on("GET", "/api/jobs/j_9a4c66f1f8cd", try SessionFixtures.reply(done))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        #expect(model.actions?.rerunTitle == "Analyze film")
        #expect(model.actions?.showsFullReanalysis == false)

        await model.rerun()

        #expect(posts(h, "\(gamePath)/jobs").first?.bodyText == #"{"kind":"analyze"}"#)
        #expect(toasts.current?.text == "Analysis started")
    }

    @Test func nothingStartsWhileTheButtonIsDisabled() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("game_queued.json"))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        await model.rerun()
        model.requestFullReanalysis()

        #expect(posts(h, "\(gamePath)/jobs").isEmpty)
        #expect(model.confirmation == nil)
        #expect(toasts.current == nil)
    }

    // MARK: - Full re-analysis (03 §7.4)

    @Test func fullReanalysisAsksWithTheWebTextThenStartsAnAnalyze() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_analyze_full.json", status: 201))
        h.server.on("GET", "/api/jobs/j_9a4c66f1f8cd", .fixture("job_cancelled_2_cancelled_done.json"))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        model.requestFullReanalysis()

        let request = try #require(model.confirmation)
        #expect(request.title == "Send the film to the GPU again?")
        #expect(request.message == Game.fullReanalysisConfirmation(showsResults: true).message)
        #expect(request.message?.contains(" The current results stay on this page until it finishes.") == true)
        #expect(request.confirmTitle == "Send to GPU")
        #expect(request.isDestructive)
        #expect(posts(h, "\(gamePath)/jobs").isEmpty)  // nothing before the coach confirms

        await model.startFullReanalysis()

        #expect(posts(h, "\(gamePath)/jobs").first?.bodyText == #"{"kind":"analyze"}"#)
        #expect(toasts.current?.text == "Full re-analysis started")
    }

    @Test func withoutResultsOnThePageTheQuestionLeavesOutTheirSentence() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let model = GameDetailModel(context: GameContext.preview(game: game), toasts: nil)

        model.requestFullReanalysis()

        #expect(model.confirmation?.message == Game.fullReanalysisConfirmation(showsResults: false).message)
        #expect(model.confirmation?.message?.contains("The current results stay") == false)
    }

    // MARK: - Errors of the header actions (game.js `startJob`; 09 R36)

    @Test func aRefusedStartReloadsThePageAndShowsTheError() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        let loads = h.server.count("GET", gamePath)

        await model.rerun()

        #expect(h.server.count("GET", gamePath) == loads + 1)
        let error = try #require(actionError(model))
        #expect(error.title == "Conflict")
        #expect(error.message == "This game's film is being analysed right now.")
        #expect(error.hint == "Wait for it to finish, or cancel it first.")
        #expect(toasts.current == nil)
        #expect(!model.isWorking)
    }

    @Test func theErrorStaysUntilThePageMovesOn() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        await model.rerun()

        // A reload that finds nothing new keeps the box …
        await context.refresh()
        #expect(actionError(model)?.title == "Conflict")

        // … one that finds the game changed (the other job ended) clears it, as the web's next refresh does.
        let later = try SessionFixtures.game("game_ready.json") {
            $0.updatedAt = ScoutTimestamp.date(from: "2026-11-11T20:30:00Z")
        }
        h.server.on("GET", gamePath, try SessionFixtures.reply(later))
        await context.refresh()
        #expect(model.pageError == nil)
    }

    @Test func pullToRefreshClearsTheError() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        await model.rerun()
        #expect(actionError(model) != nil)

        await model.refresh()

        #expect(model.pageError == nil)
    }

    @Test func aRejectedPasswordShowsNothingAndAsksToSignIn() async throws {
        // 09 R6: the lockout gate handles a 401; the page shows no error of its own.
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_401_wrong_password.json", status: 401))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        await model.rerun()

        #expect(model.pageError == nil)
        #expect(toasts.current == nil)
        #expect(h.session.state == .needsPassword(message: ServerSession.passwordRejectedMessage))
        #expect(h.session.client == nil)
    }

    // MARK: - Page load errors (03 §7.3 step 1)

    @Test func aMissingGameOffersTheWayBack() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("err_404_unknown_game.json", status: 404))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }

        await context.refresh()

        guard case .load(let error, let canGoBack)? = model.pageError else {
            Issue.record("expected the load error")
            return
        }
        #expect(error.title == "Not found")
        #expect(!error.isRetryable)
        #expect(canGoBack)
        #expect(model.header == nil)
        #expect(model.actions == nil)
    }

    @Test func anAnalysisThatCannotBeLoadedLeavesTheGameOnThePage() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/analysis", SessionFixtures.error(
            500, code: "ANALYSIS_FAILED", title: "Analysis failed", message: "The saved analysis could not be read.", retryable: true))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }

        await context.refresh()

        guard case .load(let error, let canGoBack)? = model.pageError else {
            Issue.record("expected the load error")
            return
        }
        #expect(error.title == "Analysis failed")
        #expect(error.isRetryable)
        #expect(!canGoBack)
        #expect(model.header?.title == "Test Team A vs Test Team B")
    }

    // MARK: - Team confirmation (03 §7.6)

    @Test func confirmingTheScoutedTeamThanksAndReloads() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("game_ready.json"), .fixture("game_patch_team_id_map.json"))
        h.server.on("PATCH", gamePath, .fixture("game_patch_team_id_map.json"))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        let choices = model.teamChoices
        try #require(choices.count == 2)

        await model.chooseTeam(choices[0])

        let patch = try #require(h.server.requests.first { $0.method == "PATCH" })
        #expect(patch.path == gamePath)
        #expect(patch.bodyText == #"{"team_id_map":{"0":"scouted","1":"other"}}"#)
        #expect(patch.header("Content-Type") == "application/json")
        #expect(toasts.current?.text == "Thanks - teams confirmed.")
        #expect(toasts.current?.tone == .success)
        #expect(posts(h, "\(gamePath)/jobs").isEmpty)
        #expect(h.server.count("GET", gamePath) == 2)
        #expect(model.teamChoices.isEmpty)  // the map is set: no more banner
        #expect(model.savingTeamID == nil)
    }

    @Test func choosingTheOtherTeamRerunsTheAnalysis() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("PATCH", gamePath, .fixture("game_patch_team_id_map.json"))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        await model.chooseTeam(model.teamChoices[1])

        let patchIndex = try #require(h.server.requests.firstIndex { $0.method == "PATCH" })
        let postIndex = try #require(h.server.requests.firstIndex { $0.method == "POST" })
        #expect(patchIndex < postIndex)
        #expect(h.server.requests[patchIndex].bodyText == #"{"team_id_map":{"0":"other","1":"scouted"}}"#)
        #expect(h.server.requests[postIndex].bodyText == #"{"kind":"reanalyze"}"#)
        #expect(toasts.current?.text == "Re-running the analysis\u{2026}")
    }

    @Test func whileTheChoiceIsSavedTheButtonsWait() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let held = HeldReply { .fixture("game_patch_team_id_map.json") }
        h.server.on("PATCH", gamePath, .held(held))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        let choice = model.teamChoices[0]

        let saving = Task { await model.chooseTeam(choice) }
        try await waitUntil("the PATCH to wait") { held.isWaiting }

        #expect(model.savingTeamID == choice.teamID)
        #expect(model.isWorking)
        #expect(model.actions?.canRerun == false)
        #expect(model.actions?.canFullReanalysis == false)

        held.release()
        await saving.value
        #expect(model.savingTeamID == nil)
        #expect(!model.isWorking)
    }

    @Test func aFailedChoiceShowsThePageError() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("PATCH", gamePath, SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let (context, model, toasts) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        await model.chooseTeam(model.teamChoices[1])

        #expect(actionError(model)?.title == "Unexpected error")
        #expect(posts(h, "\(gamePath)/jobs").isEmpty)
        #expect(toasts.current == nil)
        #expect(model.teamChoices.count == 2)
    }

    // MARK: - Job panel: Cancel (03 §7.5)

    @Test func cancelAsksThenSendsAndSaysCancellingMeanwhile() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let running = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let poll = HeldReply { .fixture("job_analyze_1_running_gpu_processing.json") }
        h.server.on("GET", "/api/jobs/\(running.id)", .held(poll))
        let requested = try SessionFixtures.job("job_analyze_1_running_gpu_processing.json") {
            $0.cancelRequested = true
            $0.message = "Cancelling..."
            $0.updatedAt = ScoutTimestamp.date(from: "2026-11-11T20:01:05Z")
        }
        let cancelReply = HeldReply { (try? SessionFixtures.reply(requested)) ?? .empty(500) }
        h.server.on("POST", "/api/jobs/\(running.id)/cancel", .held(cancelReply))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        context.track(job: running)
        try await waitUntil("the job to be followed") { poll.isWaiting }

        model.requestCancel(running)
        let request = try #require(model.confirmation)
        #expect(request.title == "Stop this job? You can start it again later.")
        #expect(request.message == nil)
        #expect(request.confirmTitle == "Stop job")
        #expect(request.cancelTitle == "Keep running")
        #expect(request.isDestructive)

        let cancelling = Task { await model.cancel(running) }
        try await waitUntil("the cancel to be sent") { cancelReply.isWaiting }
        guard case .active(let sending) = model.jobPanel else {
            Issue.record("expected the active panel")
            return
        }
        #expect(sending.cancelTitle == "Cancelling\u{2026}")
        #expect(!sending.canCancel)

        cancelReply.release()
        await cancelling.value
        guard case .active(let after) = model.jobPanel else {
            Issue.record("expected the active panel")
            return
        }
        #expect(after.cancelTitle == "Cancelling\u{2026}")
        #expect(!after.canCancel)
        #expect(model.cancellingJobID == nil)
        #expect(posts(h, "/api/jobs/\(running.id)/cancel").count == 1)
    }

    @Test func aFailedCancelEnablesCancelAgainAndShowsTheErrorInThePanel() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let running = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let poll = HeldReply { .fixture("job_analyze_1_running_gpu_processing.json") }
        h.server.on("GET", "/api/jobs/\(running.id)", .held(poll))
        h.server.on("POST", "/api/jobs/\(running.id)/cancel", SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        context.track(job: running)
        try await waitUntil("the job to be followed") { poll.isWaiting }

        await model.cancel(running)

        #expect(model.visiblePanelError?.title == "Unexpected error")
        #expect(model.pageError == nil)
        guard case .active(let panel) = model.jobPanel else {
            Issue.record("expected the active panel")
            return
        }
        #expect(panel.cancelTitle == "Cancel")
        #expect(panel.canCancel)
    }

    @Test func aCancelThatComesTooLateSaysWhatItStillDoes() throws {
        let late = try Fixture.decode(Job.self, "job_analyze_3_running_analyzing.json")
        let model = GameDetailModel(
            context: GameContext.preview(game: try Fixture.decode(Game.self, "game_processing.json"), jobs: [late]), toasts: nil)

        model.requestCancel(late)

        let request = try #require(model.confirmation)
        #expect(request.title == "Too late to stop the analysis: the new GPU results are already in place, so it will finish.")
        #expect(request.message == "Cancelling now only skips the automatic scouting report, if one was going to be written.")
        #expect(request.confirmTitle == "Cancel anyway")
        #expect(request.cancelTitle == "Keep running")
    }

    @Test func aJobWhoseCancelWasRequestedCannotBeCancelledAgain() throws {
        let requested = try Fixture.decode(Job.self, "job_cancel_running.json")
        let model = GameDetailModel(
            context: GameContext.preview(game: try Fixture.decode(Game.self, "game_processing.json"), jobs: [requested]), toasts: nil)

        model.requestCancel(requested)

        #expect(model.confirmation == nil)
    }

    // MARK: - Job panel: Start again / Retry (03 §7.5)

    @Test func startAgainOfACancelledFullRunAsksFirst() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let cancelled = try Fixture.decode(Job.self, "job_cancelled_2_cancelled_done.json")  // ANALYZE j_9a4c66f1f8cd
        h.server.on("GET", "\(gamePath)/jobs", try SessionFixtures.reply([cancelled]))
        h.server.on("POST", "/api/jobs/\(cancelled.id)/retry", .fixture("job_retry_analyze.json"))
        h.server.on("GET", "/api/jobs/j_6d97c2b25cbf", .fixture("job_late_cancel_2_succeeded_done.json"))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        guard case .cancelled(let panel) = model.jobPanel else {
            Issue.record("expected the cancelled panel")
            return
        }
        #expect(panel.needsConfirmation)

        model.requestRestart(cancelled)

        let request = try #require(model.confirmation)
        #expect(request.title == "Send the film to the GPU again?")
        #expect(request.confirmTitle == "Send to GPU")
        #expect(posts(h, "/api/jobs/\(cancelled.id)/retry").isEmpty)

        await model.restart(cancelled)

        #expect(posts(h, "/api/jobs/\(cancelled.id)/retry").count == 1)
        #expect(model.visiblePanelError == nil)
        #expect(model.restartingJobID == nil)
    }

    @Test func retryOfAReanalysisStartsAtOnce() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let failed = try SessionFixtures.job("job_reanalyze_3_succeeded_done.json") {
            $0.status = .failed
            $0.stage = .analyzing
            $0.error = ErrorInfo(code: ErrorCode.analysisFailed, title: "Analysis failed", message: "The box score could not be built.", retryable: true)
        }
        h.server.on("GET", "\(gamePath)/jobs", try SessionFixtures.reply([failed]))
        h.server.on("POST", "/api/jobs/\(failed.id)/retry", .fixture("job_retry_cancelled.json"))  // j_9d3fd8a5e848
        let done = try SessionFixtures.job("job_retry_cancelled.json") {
            $0.status = .succeeded
            $0.stage = .done
            $0.progress = 100
        }
        h.server.on("GET", "/api/jobs/j_9d3fd8a5e848", try SessionFixtures.reply(done))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()
        guard case .failed(let panel) = model.jobPanel else {
            Issue.record("expected the failed panel")
            return
        }
        #expect(panel.action == .retry)
        #expect(!panel.needsConfirmation)

        model.requestRestart(failed)

        #expect(model.confirmation == nil)
        try await waitUntil("the retry to be sent and followed") {
            posts(h, "/api/jobs/\(failed.id)/retry").count == 1 && model.restartingJobID == nil
        }
        #expect(model.visiblePanelError == nil)
    }

    @Test func aFailedRetryShowsItsErrorInThePanel() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let failed = try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")
        let retryable = try SessionFixtures.job("job_failed_1_failed_preparing.json") {
            $0.gameID = "g_e934f8c21058"
            $0.error?.retryable = true
        }
        h.server.on("GET", "\(gamePath)/jobs", try SessionFixtures.reply([retryable]))
        h.server.on("POST", "/api/jobs/\(failed.id)/retry", .fixture("err_409_retry_video_missing.json", status: 409))
        let (context, model, _) = page(h)
        defer { context.stopTracking() }
        await context.refresh()

        await model.restart(retryable)

        #expect(model.visiblePanelError?.title == "No video")
        #expect(model.pageError == nil)
        guard case .failed(let panel) = model.jobPanel else {
            Issue.record("expected the failed panel")
            return
        }
        #expect(panel.action == .retry)
    }

    // MARK: - What the page shows

    @Test func theJobPanelUsesThePagesClock() throws {
        let running = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let model = GameDetailModel(
            context: GameContext.preview(game: try Fixture.decode(Game.self, "game_processing.json"), jobs: [running]),
            toasts: nil, now: { Self.now })

        guard case .active(let panel) = model.jobPanel else {
            Issue.record("expected the active panel")
            return
        }
        #expect(panel.details.hasSuffix("running for 3 min 20 s"))
        #expect(model.actions?.canRerun == false)
        #expect(model.actions?.rerunHelp == "An analysis is already running")
    }

    @Test func noBannerWithoutAnAnalysis() throws {
        let model = GameDetailModel(context: GameContext.preview(game: try Fixture.decode(Game.self, "game_ready.json")), toasts: nil)
        #expect(model.teamChoices.isEmpty)
    }
}
