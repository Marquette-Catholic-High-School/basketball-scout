import Foundation
import Testing
@testable import BasketballScout

/// The "Game details" form (03 §7.2, 04 §6.1 step 1; 09 D1 #3): the web's clean-up, "Team name needed"
/// without a request, `POST /api/games`, errors through the lockout gate, and a lost answer that must not
/// make a second game (09 C11).
@MainActor
struct NewGameFormModelTests {
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A calendar in a fixed zone, so a picked moment is one known day.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
        return calendar
    }

    private func signedIn() async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        return h
    }

    /// The JSON body of the one `POST /api/games`.
    private func sentBody(_ h: SessionHarness) throws -> [String: Any] {
        let posts = h.server.requests.filter { $0.method == "POST" && $0.path == "/api/games" }
        #expect(posts.count == 1)
        let request = try #require(posts.first)
        #expect(request.header("Content-Type")?.hasPrefix("application/json") == true)
        #expect(request.header("Authorization")?.hasPrefix("Basic ") == true)
        return try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    // MARK: - The check before any request

    @Test func aBlankTeamNameIsRefusedWithoutARequest() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        let before = h.server.requests.count
        let model = NewGameFormModel(calendar: calendar)
        model.setText("   \n ", for: .scoutedTeam)
        model.setText("Test Team B", for: .otherTeam)

        let game = await model.create(session: h.session)

        #expect(game == nil)
        #expect(model.problem?.title == "Team name needed")
        #expect(model.problem?.message == "Enter the name of the team you are scouting.")
        #expect(model.invalidField == .scoutedTeam)
        #expect(h.server.requests.count == before)

        model.setText("Test Team A", for: .scoutedTeam)
        #expect(model.invalidField == nil)
    }

    // MARK: - The body (09 D1 #3)

    @Test func everyTextIsTrimmedAndEmptyFieldsAreNull() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        h.server.on("POST", "/api/games", .fixture("game_create_minimal.json", status: 201))
        let model = NewGameFormModel(calendar: calendar)
        model.setText("  Test Team C \n", for: .scoutedTeam)
        model.setText("   ", for: .otherTeam)
        model.setText(" ", for: .location)
        model.setText("", for: .level)
        model.setText("\n\n", for: .notes)

        let game = await model.create(session: h.session)

        #expect(game?.id == "g_3864d2c4f9c8")
        #expect(model.problem == nil)
        let json = try sentBody(h)
        #expect(json["scouted_team"] as? String == "Test Team C")
        // `other_team` is never null (null → 422): "" when empty.
        #expect(json["other_team"] as? String == "")
        #expect(json["game_date"] is NSNull)
        #expect(json["location"] is NSNull)
        #expect(json["level"] is NSNull)
        #expect(json["notes"] is NSNull)
        #expect(json["scouted_color"] as? String == "dark")
        // The web never sends a title.
        #expect(json["title"] == nil || json["title"] is NSNull)
    }

    @Test func aFullFormIsSentAsTheWebSendsIt() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        h.server.on("POST", "/api/games", .fixture("game_create.json", status: 201))
        let model = NewGameFormModel(calendar: calendar)
        model.setText(" Test Team A ", for: .scoutedTeam)
        model.setText("Test Team B", for: .otherTeam)
        model.hasGameDate = true
        // 23:30 in Chicago on Nov 7 is already Nov 8 in UTC: the picked day is sent, not the UTC one.
        model.gameDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 30)))
        model.setText("Test Gym", for: .location)
        model.setText("Varsity", for: .level)
        model.setText("Fixture game ", for: .notes)
        model.jersey = .light

        let game = await model.create(session: h.session)

        #expect(game?.displayTitle == "Test Team A vs Test Team B")
        let json = try sentBody(h)
        #expect(json["scouted_team"] as? String == "Test Team A")
        #expect(json["other_team"] as? String == "Test Team B")
        #expect(json["game_date"] as? String == "2026-11-07")
        #expect(json["location"] as? String == "Test Gym")
        #expect(json["level"] as? String == "Varsity")
        #expect(json["notes"] as? String == "Fixture game")
        #expect(json["scouted_color"] as? String == "light")
    }

    @Test func aPickedColourIsSentAsLowercaseHex() {
        let model = NewGameFormModel(calendar: calendar)
        model.setText("Test Team A", for: .scoutedTeam)
        #expect(model.request.scoutedColor == "dark")
        model.jersey = .pick
        #expect(model.request.scoutedColor == "#1f3a93")
        model.pickedColor = HexColor(0xC8102E)
        #expect(model.request.scoutedColor == "#c8102e")
    }

    @Test func noDateUnlessOneIsSet() throws {
        let model = NewGameFormModel(calendar: calendar)
        model.gameDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9)))
        #expect(model.gameDay == nil)
        model.hasGameDate = true
        #expect(model.gameDay?.description == "2026-03-04")
    }

    @Test func textPastTheServersLimitIsDropped() {
        let model = NewGameFormModel(calendar: calendar)
        model.setText(String(repeating: "a", count: 130), for: .scoutedTeam)
        #expect(model.text(.scoutedTeam).count == 120)
        model.setText(String(repeating: "b", count: 41), for: .level)
        #expect(model.text(.level).count == 40)
        model.setText(String(repeating: "c", count: 5001), for: .notes)
        #expect(model.text(.notes).count == 5000)
        model.setText(String(repeating: "d", count: 201), for: .location)
        #expect(model.text(.location).count == 200)
    }

    @Test func somethingEnteredIsNoticed() {
        let model = NewGameFormModel(calendar: calendar)
        #expect(!model.hasEnteredSomething)
        model.setText("  ", for: .notes)
        #expect(!model.hasEnteredSomething)
        model.jersey = .light
        #expect(model.hasEnteredSomething)
        model.jersey = .dark
        model.hasGameDate = true
        #expect(model.hasEnteredSomething)
        model.hasGameDate = false
        model.setText("Test Team A", for: .scoutedTeam)
        #expect(model.hasEnteredSomething)
    }

    // MARK: - Errors

    @Test func aRefusalIsShownVerbatim() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        h.server.on("POST", "/api/games", .fixture("err_422_create_game_too_long.json", status: 422))
        let model = NewGameFormModel(calendar: calendar)
        model.setText("Test Team A", for: .scoutedTeam)

        let game = await model.create(session: h.session)

        #expect(game == nil)
        #expect(model.problem?.title == "Invalid input")
        #expect(model.problem?.message == "Some fields are invalid. scouted_team: String should have at most 120 characters; game_date: Input should be a valid date or datetime, invalid character in year")
        #expect(!model.isCreating)
        // A refusal is not a lost answer: the list is not read.
        #expect(h.server.count("GET", "/api/games") == 0)
    }

    @Test func aWrongPasswordGoesToTheLockoutGateAndShowsNothing() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        h.server.on("POST", "/api/games", .fixture("err_401_wrong_password.json", status: 401))
        let model = NewGameFormModel(calendar: calendar)
        model.setText("Test Team A", for: .scoutedTeam)

        let game = await model.create(session: h.session)

        #expect(game == nil)
        #expect(model.problem == nil)
        #expect(!h.session.isSignedIn)
        #expect(h.stops.contains(.passwordRejected))
    }

    @Test func nothingIsSentWhenSignedOut() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = NewGameFormModel(calendar: calendar)
        model.setText("Test Team A", for: .scoutedTeam)

        let game = await model.create(session: h.session)

        #expect(game == nil)
        #expect(model.problem == nil)
        #expect(h.server.requests.isEmpty)
    }

    // MARK: - A lost answer (09 C11)

    @Test func aLostAnswerAdoptsTheGameTheServerMade() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        let made = try SessionFixtures.game("game_create.json") { $0.createdAt = createdAt.addingTimeInterval(2) }
        let older = try SessionFixtures.game("game_ready.json") { $0.id = "g_000000000001" }
        h.server.on("POST", "/api/games", .failure(URLError(.networkConnectionLost)))
        h.server.on("GET", "/api/games", try SessionFixtures.reply([made, older]))
        let model = filledModel()

        let game = await model.create(session: h.session, knownGameIDs: [older.id], now: { createdAt })

        #expect(game?.id == made.id)
        #expect(model.problem == nil)
        #expect(h.server.count("POST", "/api/games") == 1)
        #expect(h.server.count("GET", "/api/games") == 1)
    }

    @Test func aLostAnswerWithoutTheGameShowsTheNetworkProblem() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        let known = try SessionFixtures.game("game_create.json") { $0.createdAt = createdAt }
        h.server.on("POST", "/api/games", .failure(URLError(.networkConnectionLost)))
        h.server.on("GET", "/api/games", try SessionFixtures.reply([known]))
        let model = filledModel()

        let game = await model.create(session: h.session, knownGameIDs: [known.id], now: { createdAt })

        #expect(game == nil)
        let problem = try #require(model.problem)
        #expect(problem.isRetryable)
        #expect(h.server.count("POST", "/api/games") == 1)
    }

    @Test func aRequestThatNeverLeftDoesNotReadTheList() async throws {
        let h = try await signedIn()
        defer { h.cleanUp() }
        h.server.on("POST", "/api/games", .failure(URLError(.cannotConnectToHost)))
        let model = filledModel()

        let game = await model.create(session: h.session, now: { createdAt })

        #expect(game == nil)
        #expect(model.problem != nil)
        #expect(h.server.count("GET", "/api/games") == 0)
    }

    /// The form as `game_create.json` was made.
    private func filledModel() -> NewGameFormModel {
        let model = NewGameFormModel(calendar: calendar)
        model.setText("Test Team A", for: .scoutedTeam)
        model.setText("Test Team B", for: .otherTeam)
        model.hasGameDate = true
        model.gameDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12)) ?? Date()
        model.setText("Test Gym", for: .location)
        model.setText("Varsity", for: .level)
        model.setText("Fixture game", for: .notes)
        return model
    }
}
