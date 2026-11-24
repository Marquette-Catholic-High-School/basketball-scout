import Foundation
import Testing
@testable import BasketballScout

/// A signed-in roster page against the stub server (`SessionHarness`): a page model with an instant analysis
/// poll and its own toast center. Fixtures only ("Test Player N", "Test Team A/B").
@MainActor
final class RosterTestHarness {
    static let gameID = "g_e934f8c21058"
    static let gamePath = "/api/games/\(gameID)"

    let session: SessionHarness
    let context: GameContext
    let toasts: ToastCenter
    let model: RosterPageModel

    var server: SessionStubServer { session.server }

    /// - Parameter now: the page model's clock (refetch throttle).
    init(now: @escaping () -> Date = { Date() }) async throws {
        session = SessionHarness()
        try await session.signIn()
        let defaults = UserDefaults(suiteName: "RosterTests.\(UUID().uuidString)") ?? .standard
        toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
        context = GameContext(
            gameID: Self.gameID, session: session.session, toasts: toasts, analysisCache: session.cache,
            defaults: defaults, sleeper: RecordingSleeper().sleeper)
        model = RosterPageModel(context: context, sleeper: RecordingSleeper().sleeper, now: now)
    }

    func cleanUp() {
        context.stopTracking()
        session.cleanUp()
    }

    /// A game with GPU results and an analysis whose latest job (a re-analysis) has finished, the final
    /// rosters and the analysis's tracks (with two overrides: track 7 → Test Player 5, track 13 ignored).
    func serveReadyGame(tracks: String = "tracks.json", latestJob: String = "job_get.json") {
        server.on("GET", Self.gamePath, .fixture("game_ready.json"))
        server.on("GET", "\(Self.gamePath)/rosters", .fixture("rosters_get_final.json"))
        server.on("GET", "/api/jobs/j_ffaf913e4144", .fixture(latestJob))
        server.on("GET", "\(Self.gamePath)/tracks", .fixture(tracks))
    }

    /// Serves `serveReadyGame()` and loads the page.
    func loadReadyGame(tracks: String = "tracks.json", latestJob: String = "job_get.json") async {
        serveReadyGame(tracks: tracks, latestJob: latestJob)
        await model.refresh()
    }

    /// Requests to `method path`, in order.
    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        server.requests.filter { $0.method == method && $0.path == path }
    }

    /// "METHOD path" of every request after sign-in (the sign-in's health checks left out).
    var routeLog: [String] {
        server.requests.filter { !$0.path.hasPrefix("/api/health") }.map { "\($0.method) \($0.path)" }
    }

    /// How many requests the stub server received so far.
    func requestCount() -> Int { server.requests.count }

    /// The JSON object a request sent.
    static func json(_ request: RecordedRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    /// A JSON reply of any model.
    static func reply<T: Encodable>(_ value: T, status: Int = 200) throws -> ServiceStubReply {
        .json(status, try ScoutJSON.encode(value))
    }

    /// The final rosters fixture.
    static func finalRosters() throws -> GameRosters {
        try Fixture.decode(GameRosters.self, "rosters_get_final.json")
    }

    /// The tracks fixture.
    static func tracks(_ name: String = "tracks.json") throws -> TrackState {
        try Fixture.decode(TrackState.self, name)
    }

    /// The server's error body.
    static func error(_ status: Int, code: String, title: String, message: String, retryable: Bool = false) -> ServiceStubReply {
        SessionFixtures.error(status, code: code, title: title, message: message, retryable: retryable)
    }
}

/// Editors and track state without a server, for the rules tests.
nonisolated enum RosterTestState {
    /// Both editors loaded from the final rosters fixture (players p_fixture01–10, "Test Player 1–10").
    static func editors() throws -> RosterEditors {
        let rosters = try Fixture.decode(GameRosters.self, "rosters_get_final.json")
        var editors = RosterEditors()
        editors.scouted.load(rosters.scouted)
        editors.other.load(rosters.other)
        return editors
    }

    /// The tracks fixture shown.
    static func tracks(_ name: String = "tracks.json") throws -> RosterTracksState {
        var tracks = RosterTracksState()
        tracks.show(try Fixture.decode(TrackState.self, name))
        return tracks
    }

    /// A row with the given cells.
    static func row(
        _ jersey: String, _ first: String = "", _ last: String = "", serverID: String? = nil,
        position: String = "", notes: String = ""
    ) -> RosterRowDraft {
        RosterRowDraft(serverID: serverID, jersey: jersey, firstName: first, lastName: last, position: position, notes: notes)
    }
}
