import Foundation
import Testing
@testable import BasketballScout

/// The games list's own logic (07 §3; 03 §7.1): the team-name search, deleting a game (07 §3.7) through the
/// lockout gate, the page error box, and reading the server's health again for the System status row.
@MainActor
struct GamesListModelTests {
    /// Toasts that stay on screen and are never spoken (no timers left behind).
    private static func silentToasts() -> ToastCenter {
        ToastCenter(sleep: { _ in throw CancellationError() }, announce: { _ in })
    }

    // MARK: - Search

    @Test func aBlankSearchKeepsEveryGameInTheServersOrder() throws {
        let games = try Fixture.decode([Game].self, "games_list.json")
        #expect(games.count == 3)
        #expect(GamesListModel.filter(games, query: "").map(\.id) == games.map(\.id))
        #expect(GamesListModel.filter(games, query: "  \n").map(\.id) == games.map(\.id))
    }

    @Test func theSearchMatchesTeamNamesAndTitles() throws {
        let games = try Fixture.decode([Game].self, "games_list.json")
        // Server order: "Link fixture game" (D vs E), "Test Team C", "Test Team A vs Test Team B".
        #expect(GamesListModel.filter(games, query: "test team b").map(\.id) == ["g_e934f8c21058"])
        #expect(GamesListModel.filter(games, query: "Team E").map(\.id) == ["g_5e21fcf0b398"])
        #expect(GamesListModel.filter(games, query: "fixture").map(\.id) == ["g_5e21fcf0b398"])
        #expect(GamesListModel.filter(games, query: "  team c ").map(\.id) == ["g_3864d2c4f9c8"])
        #expect(GamesListModel.filter(games, query: "Test Team").map(\.id) == games.map(\.id))
        #expect(GamesListModel.filter(games, query: "Test Team Z").isEmpty)
    }

    @Test func theSearchIgnoresCaseAndAccents() throws {
        var game = try Fixture.decode(Game.self, "game_get.json")
        game.otherTeam = "Test \u{00C9}quipe"
        game.displayTitle = "Test Team A vs Test \u{00C9}quipe"
        #expect(GamesListModel.filter([game], query: "equipe").count == 1)
        #expect(GamesListModel.filter([game], query: "TEST TEAM A").count == 1)
        #expect(GamesListModel.filter([game], query: "Team Q").isEmpty)
    }

    @Test func theActiveQueryIsTrimmedAndNilWhenBlank() {
        let model = GamesListModel()
        #expect(model.activeQuery == nil)
        model.searchText = "   "
        #expect(model.activeQuery == nil)
        model.searchText = " Test Team A "
        #expect(model.activeQuery == "Test Team A")
    }

    @Test func rowsCarryEachGamesJobAndUpload() throws {
        let queued = try SessionFixtures.game("game_queued.json") { $0.latestJobID = "j_a337003622c0" }
        let draft = try SessionFixtures.game("game_create_minimal.json")
        let job = try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json")
        let upload = UploadState(
            gameID: draft.id, fileName: "test-film.mp4", phase: .uploading, statusText: "Uploading\u{2026}",
            bytesSent: 5, totalBytes: 10)
        let rows = GamesListModel().rows(
            for: [queued, draft],
            job: { $0.id == queued.id ? job : nil },
            upload: { $0 == draft.id ? upload : nil })
        #expect(rows.map(\.id) == [queued.id, draft.id])
        #expect(rows[0].analysis?.text == "Waiting for the background worker \u{00B7} 0% \u{00B7} Waiting for a worker")
        #expect(rows[0].upload == nil)
        #expect(rows[1].analysis == nil)
        #expect(rows[1].upload?.bar == .value(0.5))
        #expect(rows.allSatisfy { !$0.isDeleting })
    }

    @Test func aRowRedrawsOnlyWhenWhatItShowsChanges() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let shown = GamesRowModel(game: game, job: nil, upload: nil)
        #expect(GamesRow(model: shown) {} == GamesRow(model: shown) {})
        #expect(GamesRow(model: shown) {} != GamesRow(model: GamesRowModel(game: game, job: nil, upload: nil, isDeleting: true)) {})
    }

    // MARK: - Delete (07 §3.7)

    @Test func theDeleteQuestionIsTheWebsText() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        var confirmed = false
        let request = GamesListModel.deleteConfirmation(for: game) { confirmed = true }
        #expect(request.title == "Delete \"Test Team A vs Test Team B\"?")
        #expect(request.message == "This removes the film, analysis, rosters and reports for this game. It cannot be undone.")
        #expect(request.confirmTitle == "Delete")
        #expect(request.isDestructive)
        #expect(request.cancelTitle == "Cancel")
        request.action()
        #expect(confirmed)
    }

    @Test func aDeleteRemovesTheGameReloadsTheListAndSaysSo() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        let other = try SessionFixtures.game("game_create_minimal.json")
        h.server.on("GET", "/api/games", try SessionFixtures.reply([ready, other]), try SessionFixtures.reply([other]))
        h.server.on("DELETE", "/api/games/\(ready.id)", .empty(204))
        let store = GamesStore(session: h.session)
        let toasts = Self.silentToasts()
        let model = GamesListModel()
        await store.refresh()

        await model.delete(ready, store: store, session: h.session, toasts: toasts)

        #expect(h.server.count("DELETE", "/api/games/\(ready.id)") == 1)
        #expect(h.server.count("GET", "/api/games") == 2)  // the list was loaded again
        #expect(store.games.map(\.id) == [other.id])
        #expect(toasts.current?.text == "Deleted Test Team A vs Test Team B")
        #expect(toasts.current?.tone == .neutral)
        #expect(model.deleteError == nil)
        #expect(!model.isDeleting(ready.id))
    }

    @Test func aFailedDeleteShowsTheErrorAndKeepsTheGame() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        h.server.on("GET", "/api/games", try SessionFixtures.reply([ready]))
        h.server.on("DELETE", "/api/games/\(ready.id)", .html(502))
        let store = GamesStore(session: h.session)
        let toasts = Self.silentToasts()
        let model = GamesListModel()
        await store.refresh()

        await model.delete(ready, store: store, session: h.session, toasts: toasts)

        #expect(model.deleteError?.title == "Server unavailable")
        #expect(store.games.map(\.id) == [ready.id])
        #expect(toasts.current == nil)
        #expect(!model.isDeleting(ready.id))
        #expect(h.session.isSignedIn)
    }

    @Test func aRejectedPasswordDuringADeleteGoesToTheSignInScreen() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        h.server.on("DELETE", "/api/games/\(ready.id)", .json(401, try Fixture.data("err_401_wrong_password.json")))
        let store = GamesStore(session: h.session)
        let model = GamesListModel()

        await model.delete(ready, store: store, session: h.session, toasts: Self.silentToasts())

        #expect(model.deleteError == nil)  // the gate took over: nothing to show here
        #expect(!h.session.isSignedIn)
        #expect(h.stops == [.passwordRejected])
    }

    @Test func aSecondDeleteOfTheSameGameWhileOneRunsIsIgnored() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        h.server.on("GET", "/api/games", try SessionFixtures.reply([ready]), try SessionFixtures.reply([Game]()))
        let held = HeldReply { .empty(204) }
        h.server.on("DELETE", "/api/games/\(ready.id)", .held(held))
        let store = GamesStore(session: h.session)
        let toasts = Self.silentToasts()
        let model = GamesListModel()
        await store.refresh()

        let first = Task { await model.delete(ready, store: store, session: h.session, toasts: toasts) }
        try await waitUntil("the delete to reach the server") { held.isWaiting }
        #expect(model.isDeleting(ready.id))
        let rows = model.rows(for: store.games, job: { _ in nil }, upload: { _ in nil })
        #expect(rows.first?.isDeleting == true)  // "Deleting…" on the row

        await model.delete(ready, store: store, session: h.session, toasts: toasts)  // returns at once
        held.release()
        await first.value

        #expect(h.server.count("DELETE", "/api/games/\(ready.id)") == 1)
        #expect(!model.isDeleting(ready.id))
        #expect(store.games.isEmpty)
    }

    @Test func aListLoadThatStartsLaterReplacesTheDeleteError() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        h.server.on("DELETE", "/api/games/\(ready.id)", .html(503))
        let store = GamesStore(session: h.session)
        let model = GamesListModel()
        model.listDidStartLoading()  // a poll already running when the delete fails…

        await model.delete(ready, store: store, session: h.session, toasts: Self.silentToasts())
        #expect(model.deleteError != nil)
        model.listDidFinishLoading()  // …does not hide the error
        #expect(model.deleteError != nil)

        model.listDidStartLoading()  // the next load replaces it (its own error, or nothing)
        #expect(model.deleteError != nil)
        model.listDidFinishLoading()
        #expect(model.deleteError == nil)
    }

    // MARK: - Health for the System status row (07 §3.8)

    @Test func healthIsReadAgainOnlyWhenTheLastAnswerIsOld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GamesListModel.healthIsStale(checkedAt: nil, now: now))
        #expect(!GamesListModel.healthIsStale(checkedAt: now, now: now))
        #expect(!GamesListModel.healthIsStale(checkedAt: now.addingTimeInterval(-59), now: now))
        #expect(GamesListModel.healthIsStale(checkedAt: now.addingTimeInterval(-60), now: now))
        #expect(GamesListModel.healthIsStale(checkedAt: now.addingTimeInterval(30), now: now))  // the clock went back
    }

    @Test func appearingReadsHealthWhenTheLastAnswerIsOld() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let checkedAt = try #require(h.session.healthCheckedAt)
        let model = GamesListModel()
        let before = h.server.count("GET", "/api/health")

        await model.refreshHealthIfStale(session: h.session, now: checkedAt.addingTimeInterval(10))
        #expect(h.server.count("GET", "/api/health") == before)

        h.server.setHealth(.fixture("health_degraded.json"))
        await model.refreshHealthIfStale(session: h.session, now: checkedAt.addingTimeInterval(61))
        #expect(h.server.count("GET", "/api/health") == before + 1)
        #expect(h.session.health?.status == .degraded)
    }

    @Test func healthIsNotReadNextToTheListWhileTheServerDidNotAnswer() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.setHealth(.html(502))
        #expect(await h.session.revalidate() == false)  // the foreground check got no answer
        #expect(h.session.connectionProblem != nil)
        let before = h.server.count("GET", "/api/health")

        await GamesListModel().refreshHealthIfStale(session: h.session, now: Date().addingTimeInterval(3600))

        // 02 §10 rule 2: the list's own load is the one request that goes first.
        #expect(h.server.count("GET", "/api/health") == before)
    }

    @Test func nothingIsReadWhileSignedOut() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        await GamesListModel().refreshHealthIfStale(session: h.session)
        #expect(h.server.requests.isEmpty)
    }

    @Test func pullToRefreshReadsTheListAndTheHealth() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .fixture("games_list.json"))
        let store = GamesStore(session: h.session)
        let before = h.server.count("GET", "/api/health")

        await GamesListModel().refresh(store: store, session: h.session)

        #expect(store.games.count == 3)
        #expect(store.hasLoaded)
        #expect(h.server.count("GET", "/api/health") == before + 1)
    }
}
