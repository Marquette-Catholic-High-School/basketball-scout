import Foundation
import Testing
@testable import BasketballScout

/// How the app follows a live game (docs/LIVE.md "Data"): the game page reads it every 10 s although its
/// status is `ready`, loads the analysis again when `live.analysis_version` moved, and stops with one full
/// reload once it has ended; "End live game" from a device that is not capturing; the games list keeps
/// refreshing while a game is live.
@MainActor
struct LiveGameFollowingTests {
    /// The game of the live fixtures.
    private let gameID = "g_bfd495c87b5c"
    private var gamePath: String { "/api/games/\(gameID)" }

    private func liveGame(_ change: (inout LiveInfo) -> Void = { _ in }) throws -> Game {
        try SessionFixtures.game("live_game_capturing.json") { game in
            var live = game.live ?? LiveInfo()
            change(&live)
            game.live = live
        }
    }

    // MARK: - The rule

    @Test func theRuleFollowsTheAnalysisVersion() throws {
        let game = try liveGame { $0.analysisVersion = 5 }
        #expect(LivePollRule.interval == .seconds(10))
        #expect(LivePollRule.shouldPoll(game))
        // The page shows the analysis of this version: only the counters move.
        #expect(LivePollRule.step(loaded: game, shownAnalysisVersion: 5) == .update)
        // The server rebuilt it, or the page shows none yet.
        #expect(LivePollRule.step(loaded: game, shownAnalysisVersion: 4) == .reloadAnalysis)
        #expect(LivePollRule.step(loaded: game, shownAnalysisVersion: nil) == .reloadAnalysis)
    }

    @Test func theRuleWaitsForTheFirstAnalysis() throws {
        // Live, but no part is analysed yet: nothing to load.
        let waiting = try Fixture.decode(Game.self, "live_game_waiting.json")
        #expect(!waiting.hasAnalysis)
        #expect(LivePollRule.shouldPoll(waiting))
        #expect(LivePollRule.step(loaded: waiting, shownAnalysisVersion: nil) == .update)
    }

    @Test func theRuleKeepsFollowingWhileTheGameIsBeingFinished() throws {
        let finishing = try liveGame {
            $0.state = .finishing
            $0.analysisVersion = 9
        }
        #expect(LivePollRule.shouldPoll(finishing))
        #expect(LivePollRule.step(loaded: finishing, shownAnalysisVersion: 9) == .update)
        #expect(LivePollRule.step(loaded: finishing, shownAnalysisVersion: 8) == .reloadAnalysis)
    }

    @Test func theRuleStopsWhenTheGameHasEndedOrIsNotLive() throws {
        let ended = try Fixture.decode(Game.self, "live_game_ended.json")
        #expect(!LivePollRule.shouldPoll(ended))
        #expect(LivePollRule.step(loaded: ended, shownAnalysisVersion: ended.live?.analysisVersion) == .ended)
        // New film made it a normal game (`live: null`), or it never was live.
        let normal = try Fixture.decode(Game.self, "game_ready.json")
        #expect(!LivePollRule.shouldPoll(normal))
        #expect(!LivePollRule.shouldPoll(nil))
        #expect(LivePollRule.step(loaded: normal, shownAnalysisVersion: nil) == .ended)
    }

    // MARK: - The game page

    private func liveServer() async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        h.server.on("GET", "\(gamePath)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list_empty.json"))
        h.server.on("GET", "\(gamePath)/reports", .fixture("reports_list_empty.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        return h
    }

    private func context(_ h: SessionHarness, sleeper: RecordingSleeper) -> GameContext {
        GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "LiveGameFollowingTests.\(UUID().uuidString)") ?? .standard,
            sleeper: sleeper.sleeper, now: h.clock.reader)
    }

    @Test func aLiveGameIsReadEvery10SecondsAndItsAnalysisReloadedWhenTheVersionMoves() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        let first = try liveGame { $0.analysisVersion = 1 }
        let moreFilm = try liveGame {
            $0.analysisVersion = 1
            $0.segmentsReceived = 3
            $0.receivedS = 360
        }
        let rebuilt = try liveGame {
            $0.analysisVersion = 2
            $0.segmentsReceived = 3
            $0.segmentsAnalysed = 3
            $0.receivedS = 360
            $0.analysedS = 360
        }
        let ended = try Fixture.decode(Game.self, "live_game_ended.json")
        h.server.on(
            "GET", gamePath,
            try SessionFixtures.reply(first),     // the page opens
            try SessionFixtures.reply(moreFilm),  // 10 s later: only the counters moved
            try SessionFixtures.reply(rebuilt),   // 10 s later: a new analysis
            try SessionFixtures.reply(rebuilt),   // … so the page reloads
            try SessionFixtures.reply(ended),     // 10 s later: over
            try SessionFixtures.reply(ended))     // … one full reload, then nothing
        let sleeper = RecordingSleeper()
        let context = context(h, sleeper: sleeper)
        defer { context.stopTracking() }

        await context.refresh()
        #expect(context.isLive)
        #expect(context.headerBadge?.text == "Live")
        try await waitUntil("the end of the live game") { context.game?.live?.state == .ended && !context.isRefreshing }
        try await Task.sleep(for: .milliseconds(30))

        // Status `ready` all along: it was the live record that kept the page reading.
        #expect(h.server.count("GET", gamePath) == 6)
        #expect(sleeper.recorded == [.seconds(10), .seconds(10), .seconds(10)])
        // Loaded when the page opened, when the version moved, and once more at the end.
        #expect(h.server.count("GET", "\(gamePath)/analysis") == 3)
        #expect(!context.isLive)
        #expect(context.headerBadge?.text == "Ready")
        #expect(context.analysis != nil)
        #expect(context.loadError == nil)
    }

    @Test func theCountersFollowWithoutReloadingTheAnalysis() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        let first = try liveGame { $0.analysisVersion = 4 }
        let later = try liveGame {
            $0.analysisVersion = 4
            $0.segmentsReceived = 9
            $0.receivedS = 1080
        }
        h.server.on("GET", gamePath, try SessionFixtures.reply(first), try SessionFixtures.reply(later))
        let context = context(h, sleeper: RecordingSleeper())

        await context.refresh()
        try await waitUntil("the newer counters") { context.game?.live?.segmentsReceived == 9 }
        context.stopTracking()

        #expect(h.server.count("GET", "\(gamePath)/analysis") == 1)
        #expect(context.game?.live?.receivedS == 1080)
    }

    @Test func readingStopsWhenThePageGoesAway() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, try SessionFixtures.reply(try liveGame { $0.analysisVersion = 1 }))
        let context = context(h, sleeper: RecordingSleeper())

        await context.refresh()
        try await waitUntil("a few reads") { h.server.count("GET", gamePath) >= 3 }
        context.stopTracking()
        try await Task.sleep(for: .milliseconds(30))
        let count = h.server.count("GET", gamePath)
        try await Task.sleep(for: .milliseconds(60))

        #expect(h.server.count("GET", gamePath) == count)
    }

    @Test func aNetworkProblemDoesNotStopTheReading() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        let game = try SessionFixtures.reply(try liveGame { $0.analysisVersion = 1 })
        let outage = SessionFixtures.error(
            502, code: "SERVER_UNAVAILABLE", title: "Server unavailable", message: "The server is restarting.", retryable: true)
        let ended = try SessionFixtures.reply(try Fixture.decode(Game.self, "live_game_ended.json"))
        h.server.on("GET", gamePath, game, outage, outage, ended)
        let context = context(h, sleeper: RecordingSleeper())
        defer { context.stopTracking() }

        await context.refresh()
        try await waitUntil("the end of the live game") { context.game?.live?.state == .ended && !context.isRefreshing }

        #expect(context.loadError == nil)
    }

    @Test func aGameThatIsNotLiveIsNotRead() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let path = "/api/games/g_e934f8c21058"
        h.server.on("GET", path, .fixture("game_ready.json"))
        h.server.on("GET", "\(path)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(path)/jobs", .fixture("jobs_list.json"))
        h.server.on("GET", "\(path)/reports", .fixture("reports_list_seeded.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        let sleeper = RecordingSleeper()
        let context = GameContext(
            gameID: "g_e934f8c21058", session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "LiveGameFollowingTests.\(UUID().uuidString)") ?? .standard,
            sleeper: sleeper.sleeper, now: h.clock.reader)
        defer { context.stopTracking() }

        await context.refresh()
        try await Task.sleep(for: .milliseconds(40))

        #expect(h.server.count("GET", path) == 1)
        #expect(sleeper.recorded.isEmpty)
    }

    // MARK: - End live game (from a device that is not capturing)

    @Test func endLiveGameAsksFirstThenTellsTheServer() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("live_game_capturing.json"))
        h.server.on("POST", "\(gamePath)/live/finish", .fixture("live_finish.json"))
        let liveJobID = try #require(try Fixture.decode(LiveStatus.self, "live_finish.json").job?.id)
        h.server.on("GET", "/api/jobs/\(liveJobID)", .fixture("live_job_running.json"))
        // The sleeper never returns here: the page reads the game only when the test says so.
        let context = GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "LiveGameFollowingTests.\(UUID().uuidString)") ?? .standard,
            sleeper: Sleeper { _ in try await Task.sleep(for: .seconds(3600)) }, now: h.clock.reader)
        defer { context.stopTracking() }
        let toasts = ToastCenter(sleep: { _ in throw CancellationError() }, announce: { _ in })
        let model = GameDetailModel(context: context, toasts: toasts)
        await context.refresh()
        #expect(model.liveBanner?.canEnd == true)
        #expect(model.canEndLive)

        model.requestEndLive()
        let question = try #require(model.confirmation)
        #expect(question.title == "End the live game?")
        #expect(question.message == "The game stops taking film. The parts already sent are analysed, then the film is put together.")
        #expect(question.confirmTitle == "End live game")
        #expect(question.cancelTitle == "Keep going")
        #expect(h.server.count("POST", "\(gamePath)/live/finish") == 0)  // nothing is sent before the answer

        await model.endLive()

        let post = try #require(h.server.requests.first { $0.method == "POST" && $0.path == "\(gamePath)/live/finish" })
        #expect(post.body.isEmpty)
        #expect(context.game?.live?.state == .finishing)
        #expect(model.liveBanner?.stateTitle == "Finishing")
        #expect(!model.canEndLive)  // no second End while it is being finished
        #expect(toasts.current?.text == "The live game is ending")
        #expect(model.pageError == nil)
    }

    @Test func aRefusedEndShowsInThePageErrorArea() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("live_game_capturing.json"))
        h.server.on("POST", "\(gamePath)/live/finish", SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let context = GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "LiveGameFollowingTests.\(UUID().uuidString)") ?? .standard,
            sleeper: Sleeper { _ in try await Task.sleep(for: .seconds(3600)) }, now: h.clock.reader)
        defer { context.stopTracking() }
        let model = GameDetailModel(context: context, toasts: nil)
        await context.refresh()

        await model.endLive()

        guard case .action(let error)? = model.pageError else {
            Issue.record("expected the end's error in the page error area")
            return
        }
        #expect(error.title == "Unexpected error")
        #expect(context.game?.live?.state == .capturing)
        #expect(model.canEndLive)
    }

    @Test func theRunningLiveJobsWarningsShowInTheBanner() async throws {
        let h = try await liveServer()
        defer { h.cleanUp() }
        let job = try SessionFixtures.job("live_job_running.json") {
            $0.warnings = ["Part 3 of the film could not be analysed: GPU out of memory"]
        }
        h.server.on("GET", gamePath, .fixture("live_game_capturing.json"))
        h.server.on("GET", "\(gamePath)/jobs", try SessionFixtures.reply([job]))
        h.server.on("GET", "/api/jobs/\(job.id)", try SessionFixtures.reply(job))
        let context = GameContext(
            gameID: gameID, session: h.session, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "LiveGameFollowingTests.\(UUID().uuidString)") ?? .standard,
            sleeper: Sleeper { _ in try await Task.sleep(for: .seconds(3600)) }, now: h.clock.reader)
        defer { context.stopTracking() }
        let model = GameDetailModel(context: context, toasts: nil)

        await context.refresh()

        #expect(model.liveWarnings == ["Part 3 of the film could not be analysed: GPU out of memory"])
        // While it is live nothing else may be started: the page is busy and offers neither film nor re-runs.
        #expect(context.isBusy)
        #expect(model.actions?.showsFilmAndAnalysisActions == false)
        #expect(model.actions?.canRerun == false)
        #expect(context.showsNoFilmCard == false)
        #expect(context.filmUnavailableNotice?.title == "The film comes after the game")
    }

    // MARK: - The games list

    @Test func theGamesListKeepsRefreshingWhileAGameIsLive() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let live = try SessionFixtures.reply([try Fixture.decode(Game.self, "live_game_capturing.json")])
        let over = try SessionFixtures.reply([try Fixture.decode(Game.self, "live_game_ended.json")])
        h.server.on("GET", "/api/games", live, live, over)
        let sleeper = RecordingSleeper()
        let store = GamesStore(session: h.session)

        let polling = Task { await store.poll(sleeper: sleeper.sleeper) }
        try await waitUntil("three loads") { h.server.count("GET", "/api/games") >= 3 && !store.isLoading }
        try await Task.sleep(for: .milliseconds(30))

        // `ready`, so not "active" in the old sense, yet read every 10 s until the game has ended.
        #expect(h.server.count("GET", "/api/games") == 3)
        #expect(sleeper.recorded == [.seconds(10), .seconds(10)])
        #expect(!store.hasLiveGames)
        #expect(store.refreshNote == nil)
        polling.cancel()
        await polling.value
    }

    @Test func theGamesListSaysWhyItKeepsUpdating() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .fixture("live_games_list.json"))
        let store = GamesStore(session: h.session)

        await store.refresh()

        #expect(store.hasLiveGames)
        #expect(!store.hasActiveGames)
        #expect(store.refreshNote == "Updating while a game is live")
        // The row needs no job: a live game shows its own line.
        #expect(h.server.requests.filter { $0.path.hasPrefix("/api/jobs/") }.isEmpty)
    }
}
