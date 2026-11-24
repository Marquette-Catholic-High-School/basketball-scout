import Foundation
import Testing
@testable import BasketballScout

/// The lockout gate (09 R6; DESIGN §4; 02 §10 rules 3–5): the first 401 to a credentialed request or a
/// 429 `AUTH_THROTTLED` stops every request, poller and upload; other errors are shown.
@MainActor
struct LockoutGateTests {
    private let gameID = "g_e934f8c21058"

    // MARK: - 401

    @Test func a401StopsEverythingAndAsksForThePassword() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let generation = h.session.generation

        let shown = h.session.report(APIError.unauthorized(nil))

        #expect(shown == nil)
        #expect(h.session.state == .needsPassword(message: ServerSession.passwordRejectedMessage))
        #expect(h.session.client == nil)
        #expect(h.session.videoFactory == nil)
        #expect(h.session.generation > generation)
        #expect(h.stops == [.passwordRejected])
        // The saved password is wrong now: a relaunch must not send it again.
        #expect(h.keychain.items.isEmpty)
        // A second 401 (another request that was in flight) changes nothing.
        #expect(h.session.report(APIError.unauthorized(nil)) == nil)
        #expect(h.stops == [.passwordRejected])
    }

    @Test func a401WhileFollowingAJobStopsTheGamesPollerToo() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let sleeper = RecordingSleeper()

        // The games list polls every "5 s" (at once with the recording sleeper) while a game is queued.
        let queued = try SessionFixtures.game("game_queued.json")
        h.server.on("GET", "/api/games", try SessionFixtures.reply([queued]))
        let store = GamesStore(session: h.session)
        let polling = Task { await store.poll(sleeper: sleeper.sleeper) }
        try await waitUntil("the games list to poll") { h.server.count("GET", "/api/games") >= 3 }

        // The game page follows a job; the server now refuses the password.
        h.server.on("GET", "/api/jobs/j_a337003622c0", .json(401, try Fixture.data("err_401_wrong_password.json")))
        let context = GameContext(gameID: gameID, session: h.session, sleeper: sleeper.sleeper)
        context.track(job: try SessionFixtures.job("job_reanalyze_1_queued_queued.json"))

        try await waitUntil("the gate to trip") { !h.session.isSignedIn }
        await polling.value  // the poller ends by itself
        let sent = h.server.requests.count
        try await Task.sleep(for: .milliseconds(50))

        #expect(h.server.requests.count == sent)
        #expect(h.server.count("GET", "/api/jobs/j_a337003622c0") == 1)
        #expect(context.jobTrackingError == nil)  // handled by the gate: nothing to show
        #expect(h.session.state == .needsPassword(message: ServerSession.passwordRejectedMessage))
    }

    @Test func anUpload401TripsTheGateAndSuspendsTheOtherUploads() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let uploadServer = FakeUploadServer(chunkSize: 1000)
        uploadServer.add(.hold, on: .chunk(0))
        uploadServer.add(.unauthorized, on: .chunk(1))
        let uploads = UploadManager(
            store: UploadStore(directory: try folder.folder("Store")), activity: FakeUploadActivity(),
            sleeper: RecordingSleeper().sleeper, progressInterval: nil)
        let appModel = AppModel(session: h.session, uploads: uploads, games: GamesStore(session: h.session), toasts: ToastCenter())
        let uploadClient = try uploadServer.client()
        uploads.clientProvider = { uploadClient }

        await uploads.start(gameID: "g_0000000000a1", film: .external(try folder.makeFilm("First.mp4", count: 2500)))
        try await waitUntil("the first chunk to be held") { uploadServer.heldReplies.first?.isWaiting == true }
        await uploads.start(gameID: "g_0000000000a2", film: .external(try folder.makeFilm("Second.mp4", count: 2500, seed: 1)))

        try await waitUntil("the gate to trip") { !h.session.isSignedIn }
        try await waitUntil("the first upload to pause") { uploads.uploads["g_0000000000a1"]?.phase == .paused }
        #expect(uploads.uploads["g_0000000000a1"]?.pauseReason == .signedOut)
        #expect(h.session.state == .needsPassword(message: ServerSession.passwordRejectedMessage))
        #expect(appModel.showNewGame == false)
    }

    // MARK: - 429

    @Test func a429AuthThrottledLocksUntilRetryAfter() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let start = h.clock.now

        let shown = h.session.report(APIError.throttled(retryAfter: 90, info: nil))

        #expect(shown == nil)
        let until = start.addingTimeInterval(90)
        #expect(h.session.state == .locked(until: until))
        #expect(h.session.client == nil)
        #expect(h.stops == [.throttled])
        // Remembered across relaunches; the password is kept (it may be right).
        #expect(h.lockouts.until(for: try h.server.address, now: start) == until)
        #expect(h.keychain.items[try h.account] == SessionHarness.password)
        #expect(h.session.savedPassword() == SessionHarness.password)
    }

    @Test func a429FromTheServerIsMappedAndGated() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .json(429, try Fixture.data("err_429_auth_throttled.json"), headers: ["Retry-After": "45"]))
        let store = GamesStore(session: h.session)

        await store.refresh()

        #expect(store.error == nil)
        #expect(h.session.state.lockedUntil != nil)
        #expect(h.session.client == nil)
    }

    @Test func reportRateLimitedIsAnOrdinaryError() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let client = try await h.signIn()
        let body = #"{"error":{"code":"REPORT_RATE_LIMITED","title":"Claude is busy","message":"Too many requests to Claude.","hint":"Try again in a minute.","retryable":true,"detail":null}}"#
        let error = APIError.from(status: 429, headers: HTTPHeaders([:]), body: Data(body.utf8))
        #expect(!error.isThrottle)

        let shown = h.session.report(error, from: client)

        #expect(shown?.title == "Claude is busy")
        #expect(h.session.state == .signedIn)
        #expect(h.session.client === client)
        #expect(h.stops.isEmpty)
    }

    // MARK: - Refusals, cancellations, other errors

    @Test func hostNotAllowedStopsEverythingAndExplains() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let info = try Fixture.decode(ErrorEnvelope.self, "err_403_host_not_allowed.json").error

        let shown = h.session.report(APIError.server(info, status: 403))

        #expect(shown == nil)
        #expect(h.session.state == .signedOut)
        #expect(h.session.problem?.title == "This server doesn't accept that name")
        #expect(h.stops == [.refusedByServer])
        #expect(h.keychain.items[try h.account] == SessionHarness.password)
    }

    @Test func cancellationsAreNeverShown() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        #expect(h.session.report(CancellationError()) == nil)
        #expect(h.session.report(APIError.cancelled) == nil)
        #expect(h.session.report(URLError(.cancelled)) == nil)
        #expect(h.session.state == .signedIn)
    }

    @Test func otherErrorsAreReturnedForDisplay() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let offline = APIError.transport(URLError(.notConnectedToInternet))
        #expect(h.session.report(offline)?.title == offline.title)
        let refused = UploadError.notAVideo(fileName: "Test Film.txt")
        #expect(h.session.report(refused)?.title == refused.title)
        #expect(h.session.state == .signedIn)
        #expect(h.stops.isEmpty)
    }

    @Test func errorsOfAnOlderClientDoNotTripTheGate() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let older = APIClient(address: try h.server.address, credentials: .none, session: ServiceStubSession.shared)

        #expect(h.session.report(APIError.unauthorized(nil), from: older) == nil)
        #expect(h.session.state == .signedIn)
        #expect(h.stops.isEmpty)
    }
}
