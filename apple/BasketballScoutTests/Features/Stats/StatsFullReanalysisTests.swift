import Foundation
import Testing
@testable import BasketballScout

/// "Full re-analysis" from the Data quality tab against a stubbed server (03 §7.4; 09 R6, R36).
@MainActor
struct StatsFullReanalysisTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }

    /// A signed-in harness whose server knows the calibrated game of the fixtures.
    private func server() async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        h.server.on("GET", gamePath, .fixture("game_with_calibration.json"))
        h.server.on("GET", "\(gamePath)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list.json"))
        h.server.on("GET", "\(gamePath)/reports", .fixture("reports_list_seeded.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        return h
    }

    private func context(_ h: SessionHarness, toasts: ToastCenter) -> GameContext {
        GameContext(
            gameID: gameID, session: h.session, toasts: toasts, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "StatsFullReanalysisTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
    }

    private func quietToasts() -> ToastCenter {
        ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
    }

    @Test func startsAnAnalyzeJobAndSaysSo() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        let created = try SessionFixtures.job("job_create_analyze_full.json")
        let done = try SessionFixtures.job("job_create_analyze_full.json") {
            $0.status = .succeeded
            $0.stage = .done
            $0.progress = 100
        }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_analyze_full.json", status: 201))
        h.server.on("GET", "/api/jobs/\(created.id)", try SessionFixtures.reply(done))
        let toasts = quietToasts()
        let context = context(h, toasts: toasts)
        await context.refresh()

        let error = await StatsFullReanalysis.start(in: context)

        #expect(error == nil)
        let post = try #require(h.server.requests.first { $0.method == "POST" })
        #expect(post.path == "\(gamePath)/jobs")
        #expect(post.bodyText == #"{"kind":"analyze"}"#)
        #expect(post.header("Content-Type") == "application/json")
        #expect(toasts.current?.text == "Full re-analysis started")
        #expect(!context.isStartingJob)
        context.stopTracking()
    }

    @Test func aRefusedStartShowsTheServersError() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let toasts = quietToasts()
        let context = context(h, toasts: toasts)
        await context.refresh()

        let error = try #require(await StatsFullReanalysis.start(in: context))

        #expect(error.title == "Conflict")
        #expect(error.message == "This game's film is being analysed right now.")
        #expect(toasts.current == nil)
        #expect(h.session.isSignedIn)
        context.stopTracking()
    }

    @Test func aRejectedPasswordGoesToTheLockoutGate() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_401_wrong_password.json", status: 401))
        let context = context(h, toasts: quietToasts())
        await context.refresh()

        let error = await StatsFullReanalysis.start(in: context)

        // Nothing to show here: the session went back to the sign-in screen.
        #expect(error == nil)
        #expect(!h.session.isSignedIn)
        context.stopTracking()
    }
}
