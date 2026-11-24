import Foundation
import Testing
@testable import BasketballScout

/// The game page's data (03 §7.3–§7.5; 09 R27, R28, R33, R36, C9, D1 #9).
@MainActor
struct GameContextTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }

    /// A signed-in harness whose server knows the ready game of the fixtures.
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

    private func context(_ h: SessionHarness, defaults: UserDefaults? = nil, clock: SessionClock? = nil) -> GameContext {
        GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: defaults ?? UserDefaults(suiteName: "GameContextTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: (clock ?? h.clock).reader)
    }

    // MARK: - Loading (03 §7.3)

    @Test func refreshLoadsTheGameFirstThenEverythingElse() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        let before = h.server.requests.count

        await context.refresh()

        let sent = Array(h.server.requests.dropFirst(before))
        #expect(sent.first?.path == gamePath)
        #expect(Set(sent.dropFirst().map(\.path)) == [
            "\(gamePath)/analysis", "\(gamePath)/jobs", "\(gamePath)/reports", "/api/court/landmarks", "/api/health",
        ])
        #expect(sent.allSatisfy { $0.method == "GET" && $0.header("Authorization") != nil })
        #expect(context.game?.status == .ready)
        #expect(context.analysis?.gameID == gameID)
        #expect(context.jobs.count == 1)
        #expect(context.reports.count == 1)
        #expect(context.landmarks != nil)
        #expect(context.health?.version == "0.1.0")
        #expect(context.loadError == nil)
        #expect(context.hasLoaded)
        #expect(!context.isRefreshing)
        #expect(context.activeAnalysisJob == nil)
    }

    @Test func theAnalysisIsOnlyRequestedWhenTheGameHasOne() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("game_get.json"))
        let context = context(h)

        await context.refresh()

        #expect(h.server.count("GET", "\(gamePath)/analysis") == 0)
        #expect(h.server.count("GET", "\(gamePath)/reports") == 0)
        #expect(context.analysis == nil)
        #expect(context.loadError == nil)
    }

    @Test func analysisNotReadyMeansNoAnalysisAndIsNotAnError() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/analysis", .fixture("err_409_analysis_not_ready.json", status: 409))
        let context = context(h)

        await context.refresh()

        #expect(context.analysis == nil)
        #expect(context.loadError == nil)
        #expect(context.game?.hasAnalysis == true)
    }

    @Test func otherAnalysisErrorsGoToThePageErrorArea() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/analysis", SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let context = context(h)

        await context.refresh()

        #expect(context.loadError?.title == "Unexpected error")
        #expect(context.loadError?.isRetryable == true)
        #expect(context.game != nil)
    }

    @Test func aMissingGameIsAPageError() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("err_404_unknown_game.json", status: 404))
        let context = context(h)

        await context.refresh()

        #expect(context.loadError?.title == "Not found")
        #expect(context.game == nil)
        #expect(context.hasLoaded)
        #expect(h.server.count("GET", "\(gamePath)/jobs") == 0)
    }

    @Test func theAnalysisIsFetchedAgainOnlyWhenTheGameChanged() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)

        await context.refresh()
        await context.refresh()
        #expect(h.server.count("GET", "\(gamePath)/analysis") == 1)

        // A new analysis job (another device re-ran it): the analysis may be new.
        h.server.on("GET", gamePath, .fixture("game_queued.json"))
        await context.refresh()
        #expect(h.server.count("GET", "\(gamePath)/analysis") == 2)
    }

    @Test func theCachedAnalysisShowsWhileTheServersDownloads() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        await h.cache.store(try Fixture.decode(GameAnalysis.self, "analysis.json"), gameID: gameID)
        let held = HeldReply { .fixture("analysis.json") }
        h.server.on("GET", "\(gamePath)/analysis", .held(held))
        let context = context(h)

        let refresh = Task { await context.refresh() }
        try await waitUntil("the cached analysis") { context.analysis != nil && held.isWaiting }
        #expect(context.isShowingCachedAnalysis)
        #expect(context.isLoadingAnalysis)

        held.release()
        await refresh.value
        #expect(!context.isShowingCachedAnalysis)
        #expect(!context.isLoadingAnalysis)
        #expect(context.analysis?.gameID == gameID)
    }

    @Test func theNewestRefreshWins() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let held = HeldReply { .fixture("game_ready.json") }
        h.server.on("GET", gamePath, .held(held), .fixture("game_queued.json"))
        let context = context(h)

        let older = Task { await context.refresh() }
        try await waitUntil("the first refresh to wait for the game") { held.isWaiting }
        await context.refresh()
        #expect(context.game?.status == .queued)

        await older.value
        #expect(held.isCancelled)  // superseded requests are cancelled (09 R36)
        held.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(context.game?.status == .queued)
        #expect(!context.isRefreshing)
    }

    // MARK: - Derived states (03 §4)

    @Test func derivedStatesOfAReadyGame() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let context = GameContext.preview(game: game, analysis: try Fixture.decode(GameAnalysis.self, "analysis.json"))
        #expect(context.hasFilm)
        #expect(context.isPlayable)
        #expect(context.rerunKind == .reanalyze)
        #expect(!context.isBusy)
        #expect(context.canRerun)
        #expect(context.showsFullReanalysis)
        #expect(!context.showsNoFilmCard)
        #expect(context.pendingNotice == nil)
        #expect(context.headerBadge?.text == "Ready")
    }

    @Test func derivedStatesOfAGameWithoutFilm() throws {
        let context = GameContext.preview(game: try Fixture.decode(Game.self, "game_get.json"))
        #expect(!context.hasFilm)
        #expect(!context.isPlayable)
        #expect(context.rerunKind == .analyze)
        #expect(!context.canRerun)
        #expect(!context.showsFullReanalysis)
        #expect(context.showsNoFilmCard)
        #expect(context.pendingNotice == nil)
    }

    @Test func derivedStatesWhileAnAnalysisRuns() throws {
        let queued = GameContext.preview(game: try Fixture.decode(Game.self, "game_queued.json"))
        #expect(queued.isBusy)
        #expect(!queued.canRerun)
        #expect(queued.headerBadge?.text == "Queued")

        let job = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let running = GameContext.preview(game: try Fixture.decode(Game.self, "game_ready.json"), jobs: [job])
        #expect(running.activeAnalysisJob?.id == job.id)
        #expect(running.isBusy)
        #expect(!running.canRerun)
        #expect(running.headerBadge?.text.hasPrefix("Processing") == true)
        #expect(running.showsJobPanel)
    }

    @Test func rerunKindFollowsTheGPUResults() throws {
        let withTracking = try SessionFixtures.game("game_ready.json") { $0.hasTracking = true }
        let withoutTracking = try SessionFixtures.game("game_ready.json") { $0.hasTracking = false }
        #expect(GameContext.preview(game: withTracking).rerunKind == .reanalyze)
        #expect(GameContext.preview(game: withoutTracking).rerunKind == .analyze)
        #expect(!GameContext.preview(game: withoutTracking).showsFullReanalysis)
    }

    @Test func teamNamesAndColours() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let analysed = GameContext.preview(game: game, analysis: try Fixture.decode(GameAnalysis.self, "analysis.json"))
        #expect(analysed.teamName(.scouted) == "Test Team A")
        #expect(analysed.teamName(.other) == "Test Team B")
        #expect(analysed.teamColor(.scouted) == HexColor(red: 24, green: 34, blue: 76))
        #expect(analysed.teamColor(.other) == HexColor(red: 238, green: 238, blue: 236))

        // Without an analysis: the game's jersey hint ("dark"), and the light opponent fallback (07 §10.3).
        let plain = GameContext.preview(game: game)
        #expect(plain.teamColor(.scouted) == TeamPalette.darkPreset)
        #expect(plain.teamColor(.other) == TeamPalette.defaultOther)
        let unnamed = GameContext.preview(game: try SessionFixtures.game("game_get.json") { $0.otherTeam = "" })
        #expect(unnamed.teamName(.other) == "Opponent")
    }

    @Test func theSelectedTabIsRememberedOnThisDevice() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: "GameContextTests.\(UUID().uuidString)"))
        let first = context(h, defaults: defaults)
        #expect(first.selectedTab == .boxScore)

        first.selectedTab = .plays
        #expect(defaults.string(forKey: GameTab.storageKey) == "plays")
        #expect(context(h, defaults: defaults).selectedTab == .plays)
    }

    // MARK: - Jobs (03 §7.4–§7.5)

    @Test func startJobPostsTheKindFollowsTheJobAndReloads() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0",
                    .fixture("job_reanalyze_2_running_analyzing.json"), .fixture("job_reanalyze_3_succeeded_done.json"))
        let context = context(h)
        await context.refresh()

        let job = try await context.startJob(.reanalyze)

        #expect(job.id == "j_a337003622c0")
        let post = try #require(h.server.requests.first { $0.method == "POST" })
        #expect(post.bodyText == #"{"kind":"reanalyze"}"#)
        #expect(post.header("Content-Type") == "application/json")
        try await waitUntil("the job to end and the page to reload") {
            context.activeAnalysisJob == nil && h.server.count("GET", gamePath) >= 3
        }
        #expect(h.server.count("GET", "/api/jobs/j_a337003622c0") == 2)
        #expect(context.filmRevision == 0)  // a re-analysis does not touch the film
        #expect(!context.isStartingJob)
    }

    /// The start returns once the server accepted the job (the toast comes at once, as on the web); the page
    /// reloads in the background.
    @Test func startJobReturnsBeforeThePageHasReloaded() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        let poll = HeldReply { .fixture("job_reanalyze_2_running_analyzing.json") }
        h.server.on("GET", "/api/jobs/j_a337003622c0", .held(poll))
        let context = context(h)
        defer { context.stopTracking() }
        await context.refresh()
        let reload = HeldReply { .fixture("game_ready.json") }
        h.server.on("GET", gamePath, .held(reload), .fixture("game_ready.json"))
        let refreshes = context.refreshCount

        let job = try await context.startJob(.reanalyze)

        #expect(job.id == "j_a337003622c0")
        #expect(context.activeAnalysisJob?.id == job.id)  // followed at once
        #expect(context.isBusy)
        #expect(!context.isStartingJob)
        try await waitUntil("the reload to ask for the game") { reload.isWaiting }
        #expect(context.refreshCount == refreshes)
        reload.release()
        try await waitUntil("the reload") { context.refreshCount == refreshes + 1 }
    }

    @Test func retryJobReturnsBeforeThePageHasReloaded() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let cancelled = try Fixture.decode(Job.self, "job_cancel_queued.json")
        h.server.on("POST", "/api/jobs/\(cancelled.id)/retry", .fixture("job_retry_cancelled.json"))
        let poll = HeldReply { .fixture("job_retry_cancelled.json") }
        h.server.on("GET", "/api/jobs/j_9d3fd8a5e848", .held(poll))
        let context = context(h)
        defer { context.stopTracking() }
        await context.refresh()
        let reload = HeldReply { .fixture("game_ready.json") }
        h.server.on("GET", gamePath, .held(reload), .fixture("game_ready.json"))
        let refreshes = context.refreshCount

        let newJob = try await context.retryJob(cancelled)

        #expect(newJob.id == "j_9d3fd8a5e848")
        #expect(context.activeAnalysisJob?.id == newJob.id)
        try await waitUntil("the reload to ask for the game") { reload.isWaiting }
        #expect(context.refreshCount == refreshes)
        reload.release()
        try await waitUntil("the reload") { context.refreshCount == refreshes + 1 }
    }

    /// A cancel whose answer already ends the job stops the job's poller: the page reloads once, and the old
    /// poll's late answer does nothing (it used to finish the job and reload the page a second time).
    @Test func aCancelThatEndsTheJobStopsItsPoller() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let running = try Fixture.decode(Job.self, "job_cancelled_1_running_gpu_processing.json")
        let poll = HeldReply { .fixture("job_cancelled_2_cancelled_done.json") }
        h.server.on("GET", "/api/jobs/\(running.id)", .held(poll))
        h.server.on("POST", "/api/jobs/\(running.id)/cancel", .fixture("job_cancelled_2_cancelled_done.json"))
        let context = context(h)
        defer { context.stopTracking() }
        context.track(job: running)
        try await waitUntil("the poll to wait") { poll.isWaiting }
        let refreshes = context.refreshCount
        let loads = h.server.count("GET", gamePath)

        let answer = try await context.cancelJob(running)

        #expect(answer.status == .cancelled)
        #expect(context.activeAnalysisJob == nil)
        #expect(context.refreshCount == refreshes + 1)
        try await waitUntil("the poll to be cancelled") { poll.isCancelled }
        poll.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(context.refreshCount == refreshes + 1)
        #expect(h.server.count("GET", gamePath) == loads + 1)
        #expect(h.server.count("GET", "/api/jobs/\(running.id)") == 1)
    }

    /// `refreshCount` grows with every refresh that drew the page (the exports tab reloads on it), not with
    /// one that could not load the game.
    @Test func refreshCountGrowsWithEveryRefreshThatDrewThePage() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)
        #expect(context.refreshCount == 0)

        await context.refresh()
        #expect(context.refreshCount == 1)
        await context.refresh()
        #expect(context.refreshCount == 2)

        h.server.on("GET", gamePath, .fixture("err_404_unknown_game.json", status: 404))
        await context.refresh()
        #expect(context.loadError != nil)
        #expect(context.refreshCount == 2)
    }

    /// After a calibration was saved or removed (game.js `onChange`): the game and the games list take the
    /// server's answer, without a request.
    @Test func updateCalibrationChangesTheGameWithoutARequest() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let store = GamesStore(session: h.session)
        let context = GameContext(
            gameID: gameID, session: h.session, gamesStore: store, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "GameContextTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
        await context.refresh()
        let sent = h.server.requests.count
        let saved = try Fixture.decode(CourtCalibration.self, "calibration_put.json")

        context.updateCalibration(saved)
        #expect(context.game?.calibration == saved)
        #expect(store.game(id: gameID)?.calibration == saved)

        context.updateCalibration(nil)
        #expect(context.game?.calibration == nil)
        #expect(store.game(id: gameID)?.calibration == nil)
        #expect(context.game?.status == .ready)
        #expect(h.server.requests.count == sent)
    }

    @Test func aRefusedStartReloadsThePageAndThrows() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let context = context(h)
        await context.refresh()
        let loads = h.server.count("GET", gamePath)

        await #expect(throws: APIError.self) {
            try await context.startJob(.analyze)
        }
        #expect(h.server.count("GET", gamePath) == loads + 1)
        #expect(!context.isStartingJob)
    }

    @Test func aFinishedAnalyzeRebuildsTheFilm() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "/api/jobs/j_ffaf913e4144", .fixture("job_analyze_4_succeeded_done.json"))
        let context = context(h)

        context.track(job: try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json"))
        #expect(context.isBusy)

        try await waitUntil("the job to end") { context.activeAnalysisJob == nil && context.hasLoaded }
        #expect(context.filmRevision == 1)
        #expect(context.latestAnalysisJob?.status == .succeeded)
    }

    @Test func followingGivesUpAndChecksAgain() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let context = context(h)

        // Unknown job (404, not retryable): following stops at once and says so.
        context.track(job: try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json"))
        try await waitUntil("following to give up") { context.jobTrackingError != nil }
        #expect(context.jobTrackingError?.title == "Not found")
        #expect(h.session.isSignedIn)

        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        context.checkJobAgain()
        #expect(context.jobTrackingError == nil)
        try await waitUntil("the job to end") { context.activeAnalysisJob == nil && context.hasLoaded }
    }

    @Test func aQueuedJobChecksTheWorkerAtMostEvery15Seconds() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let queued = ServiceStubReply.fixture("job_reanalyze_1_queued_queued.json")
        h.server.on("GET", "/api/jobs/j_a337003622c0", queued, queued, queued, .fixture("job_reanalyze_3_succeeded_done.json"))
        let context = context(h, clock: SessionClock())  // the clock stands still
        let before = h.server.count("GET", "/api/health")

        context.track(job: try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json"))
        try await waitUntil("the job to end") { context.activeAnalysisJob == nil && context.hasLoaded }

        // One worker check for three queued answers, plus the page's own health read after the job.
        #expect(h.server.count("GET", "/api/health") == before + 2)
    }

    @Test func aQueuedJobChecksTheWorkerAgainAfter15Seconds() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let queued = ServiceStubReply.fixture("job_reanalyze_1_queued_queued.json")
        h.server.on("GET", "/api/jobs/j_a337003622c0", queued, queued, queued, .fixture("job_reanalyze_3_succeeded_done.json"))
        let context = context(h, clock: SessionClock(step: 20))  // 20 s pass between readings
        let before = h.server.count("GET", "/api/health")

        context.track(job: try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json"))
        try await waitUntil("the job to end") { context.activeAnalysisJob == nil && context.hasLoaded }

        #expect(h.server.count("GET", "/api/health") == before + 4)
    }

    @Test func anActiveJobFoundByARefreshIsFollowed() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list_while_analyzing.json"), .fixture("jobs_list.json"))
        h.server.on("GET", "/api/jobs/j_ffaf913e4144", .fixture("job_analyze_4_succeeded_done.json"))
        let context = context(h)

        await context.refresh()
        #expect(context.activeAnalysisJob?.id == "j_ffaf913e4144")

        try await waitUntil("the job to end") { context.activeAnalysisJob == nil && h.server.count("GET", gamePath) >= 2 }
        #expect(h.server.count("GET", "/api/jobs/j_ffaf913e4144") == 1)
    }

    @Test func stoppingEndsFollowing() async throws {
        let h = try await readyServer()
        defer { h.cleanUp() }
        let held = HeldReply { .fixture("job_reanalyze_2_running_analyzing.json") }
        h.server.on("GET", "/api/jobs/j_a337003622c0", .held(held))
        let context = context(h)

        context.track(job: try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json"))
        try await waitUntil("the poll to wait") { held.isWaiting }
        context.stopTracking()

        try await waitUntil("the poll to be cancelled") { held.isCancelled }
    }
}
