#if os(iOS)
import Foundation
import XCTest

/// Test data for the iPhone tests, made through the test server's API (never what a test checks).
/// Every member is prefixed `iPhone` (the other testers extend the same type).
extension ScoutUITestAPI {
    /// Every game on the server (newest first).
    func iPhoneGames() async throws -> [[String: Any]] {
        (try await send("GET", "/api/games") as? [[String: Any]]) ?? []
    }

    /// One game.
    func iPhoneGame(_ gameID: String) async throws -> [String: Any] {
        (try await send("GET", "/api/games/\(gameID)") as? [String: Any]) ?? [:]
    }

    /// Deletes every game whose scouted team starts with `prefix` (left over from an interrupted run).
    func iPhoneDeleteGames(prefix: String) async {
        guard let games = try? await iPhoneGames() else { return }
        for game in games {
            if let team = game["scouted_team"] as? String, team.hasPrefix(prefix), let id = game["id"] as? String {
                await deleteGame(id)
            }
        }
    }

    /// Creates a game (more fields than `createGame`).
    func iPhoneCreateGame(team: String, other: String = "Test Opponent", level: String? = "Varsity",
                          date: String? = nil, location: String? = nil, color: String? = nil) async throws -> String {
        var body: [String: Any] = ["scouted_team": team, "other_team": other]
        if let level { body["level"] = level }
        if let date { body["game_date"] = date }
        if let location { body["location"] = location }
        if let color { body["scouted_color"] = color }
        let game = try await send("POST", "/api/games", json: body) as? [String: Any]
        guard let id = game?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    /// Uploads `film` in one chunk; `autoStart` starts the analysis (the shared helper always does).
    func iPhoneUploadFilm(gameID: String, film: URL, autoStart: Bool) async throws {
        let data = try Data(contentsOf: film)
        let session = try await send("POST", "/api/games/\(gameID)/uploads", json: [
            "filename": film.lastPathComponent, "size": data.count, "content_type": "video/mp4",
        ]) as? [String: Any]
        guard let uploadID = session?["id"] as? String else { throw URLError(.cannotParseResponse) }
        try await send("PUT", "/api/uploads/\(uploadID)/chunk?offset=0", body: data)
        try await send("POST", "/api/uploads/\(uploadID)/complete?auto_start=\(autoStart)", json: [String: Any]())
    }

    /// A game with analysed film (the shared helper, with more game details). Both rosters are saved first
    /// with "Test Player N" names for every jersey number the mock processor's synthetic game uses, so the
    /// demo server keeps them (it writes made-up demo rosters only when both are empty) and every name the
    /// analysis shows is a test name.
    func iPhoneAnalysedGame(team: String, other: String = "Test Opponent", date: String? = "2026-11-07",
                            location: String? = "Test Gym") async throws -> String {
        let id = try await iPhoneCreateGame(team: team, other: other, date: date, location: location)
        try await iPhonePutRoster(id, side: "scouted", team: nil, players: Self.iPhoneTestPlayers)
        try await iPhonePutRoster(id, side: "other", team: nil, players: Self.iPhoneTestPlayers)
        try await iPhoneUploadFilm(gameID: id, film: try ScoutUITestFilm.url(), autoStart: true)
        try await waitForGame(id, status: ["ready"])
        return id
    }

    /// Jersey, first and last name: "Test Player 1"… for the jersey numbers of the mock processor's
    /// synthetic players (scout/analysis/synthetic.py `_JERSEYS`).
    static let iPhoneTestPlayers: [(String, String, String)] = {
        let jerseys = ["0", "1", "3", "5", "11", "12", "14", "20", "22", "23", "24", "32", "40", "42", "44", "55"]
        return jerseys.enumerated().map { index, jersey in (jersey, "Test", "Player \(index + 1)") }
    }()

    /// The game's jobs, newest first.
    func iPhoneJobs(_ gameID: String) async throws -> [[String: Any]] {
        (try await send("GET", "/api/games/\(gameID)/jobs") as? [[String: Any]]) ?? []
    }

    /// Starts a job ("analyze", "reanalyze").
    @discardableResult
    func iPhoneStartJob(_ gameID: String, kind: String) async throws -> [String: Any] {
        (try await send("POST", "/api/games/\(gameID)/jobs", json: ["kind": kind]) as? [String: Any]) ?? [:]
    }

    /// Asks the server to cancel a job.
    func iPhoneCancelJob(_ jobID: String) async throws {
        try await send("POST", "/api/jobs/\(jobID)/cancel", json: [String: Any]())
    }

    /// Waits until the game's latest job is in one of `statuses` ("succeeded", "failed", "cancelled").
    func iPhoneWaitLatestJob(_ gameID: String, status statuses: Set<String>, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try await iPhoneJobs(gameID).first, let status = job["status"] as? String, statuses.contains(status) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "iPhoneAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "job of \(gameID) not \(statuses)"])
    }

    /// One side's roster ("scouted" / "other").
    func iPhoneRoster(_ gameID: String, side: String) async throws -> [String: Any] {
        (try await send("GET", "/api/games/\(gameID)/rosters/\(side)") as? [String: Any]) ?? [:]
    }

    /// Replaces one side's roster with `players` (jersey, first, last).
    func iPhonePutRoster(_ gameID: String, side: String, team: String?, players: [(String, String, String)]) async throws {
        var body: [String: Any] = [
            "players": players.map { ["jersey": $0.0, "first_name": $0.1, "last_name": $0.2] },
        ]
        if let team { body["team_name"] = team }
        try await send("PUT", "/api/games/\(gameID)/rosters/\(side)", json: body)
    }

    /// The server's health (signed in).
    func iPhoneHealth() async throws -> [String: Any] {
        (try await send("GET", "/api/health") as? [String: Any]) ?? [:]
    }

    /// Saves a video link as the game's film (`auto_start` as given).
    func iPhoneSetVideoLink(_ gameID: String, url: String, autoStart: Bool) async throws {
        try await send("POST", "/api/games/\(gameID)/video-url?auto_start=\(autoStart)", json: ["url": url])
    }

    /// Saves a court calibration (four points of the test film's court, in its pixels).
    func iPhonePutCalibration(_ gameID: String, body: [String: Any]) async throws {
        try await send("PUT", "/api/games/\(gameID)/calibration", json: body)
    }
}
#endif
