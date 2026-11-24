import Foundation
import XCTest

/// The Basketball Scout server the UI tests sign in to.
///
/// The UI tests run only against a throwaway test server (mock processor, its own data folder): they
/// create and delete games. They are skipped unless the test runner gets these variables. xcodebuild
/// passes `TEST_RUNNER_<NAME>` from its own environment to the runner as `<NAME>`:
///
///     TEST_RUNNER_SCOUT_UITEST_SERVER=http://127.0.0.1:8791 \
///     TEST_RUNNER_SCOUT_UITEST_USERNAME=coach \
///     TEST_RUNNER_SCOUT_UITEST_PASSWORD=… \
///     xcodebuild test -scheme BasketballScoutUITests -destination 'platform=iOS Simulator,name=iPhone 17'
///
/// The iOS Simulator reaches a server on the Mac at 127.0.0.1. See apple/README.md, "UI tests".
struct ScoutUITestServer: Sendable {
    let address: String
    let username: String
    let password: String

    static func fromEnvironment() throws -> ScoutUITestServer {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["SCOUT_UITEST_SERVER"], !address.isEmpty,
              let password = environment["SCOUT_UITEST_PASSWORD"], !password.isEmpty
        else {
            throw XCTSkip(
                "UI tests need a throwaway test server: set TEST_RUNNER_SCOUT_UITEST_SERVER, "
                    + "TEST_RUNNER_SCOUT_UITEST_USERNAME and TEST_RUNNER_SCOUT_UITEST_PASSWORD.")
        }
        let username = environment["SCOUT_UITEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "coach"
        return ScoutUITestServer(address: address, username: username, password: password)
    }

    /// The origin without a trailing slash.
    var origin: String {
        address.hasSuffix("/") ? String(address.dropLast()) : address
    }
}

/// Direct calls to the test server from the test runner, to set up data (for example a game whose film
/// is already analysed) without going through the screens under test. Never used for what a test checks.
struct ScoutUITestAPI: Sendable {
    let server: ScoutUITestServer

    private var authorization: String {
        let token = Data("\(server.username):\(server.password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    /// Sends a request and returns the decoded JSON body (nil for an empty body).
    @discardableResult
    func send(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil,
              contentType: String? = nil) async throws -> Any? {
        guard let url = URL(string: server.origin + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "ScoutUITestAPI", code: status, userInfo: [
                NSLocalizedDescriptionKey: "\(method) \(path) answered \(status)",
            ])
        }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    /// Creates a game and returns its id.
    func createGame(scoutedTeam: String, otherTeam: String = "Test Opponent", level: String? = "Varsity") async throws -> String {
        var body: [String: Any] = ["scouted_team": scoutedTeam, "other_team": otherTeam]
        if let level { body["level"] = level }
        let game = try await send("POST", "/api/games", json: body) as? [String: Any]
        guard let id = game?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    /// Uploads `film` in one chunk and completes the upload, which starts the analysis.
    func uploadFilm(gameID: String, film: URL) async throws {
        let data = try Data(contentsOf: film)
        let session = try await send("POST", "/api/games/\(gameID)/uploads", json: [
            "filename": film.lastPathComponent, "size": data.count, "content_type": "video/mp4",
        ]) as? [String: Any]
        guard let uploadID = session?["id"] as? String else { throw URLError(.cannotParseResponse) }
        try await send("PUT", "/api/uploads/\(uploadID)/chunk?offset=0", body: data)
        try await send("POST", "/api/uploads/\(uploadID)/complete?auto_start=true", json: [String: Any]())
    }

    /// Waits until the game's status is one of `statuses` (for example "ready").
    func waitForGame(_ gameID: String, status statuses: Set<String>, timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let game = try await send("GET", "/api/games/\(gameID)") as? [String: Any]
            if let status = game?["status"] as? String, statuses.contains(status) { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "ScoutUITestAPI", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "game \(gameID) did not reach \(statuses.sorted()) in \(Int(timeout)) s",
        ])
    }

    /// Deletes a game (ignores a missing one).
    func deleteGame(_ gameID: String) async {
        _ = try? await send("DELETE", "/api/games/\(gameID)")
    }
}
