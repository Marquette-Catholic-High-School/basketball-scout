import Foundation
import Testing
@testable import BasketballScout

/// The games list (07 §3.2, §3.7, §6 loop 1; 03 §7.1).
@MainActor
struct GamesStoreTests {
    /// A queued game whose latest job is the fixtures' queued REANALYZE.
    private func queuedGame() throws -> Game {
        try SessionFixtures.game("game_queued.json") { $0.latestJobID = "j_a337003622c0" }
    }

    @Test func refreshLoadsTheGamesAndTheJobsOfActiveGames() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let queued = try queuedGame()
        let draft = try SessionFixtures.game("game_get.json") { $0.id = "g_000000000b01" }
        h.server.on("GET", "/api/games", try SessionFixtures.reply([queued, draft]))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_1_queued_queued.json"))
        let store = GamesStore(session: h.session)

        await store.refresh()

        #expect(store.games.map(\.id) == [queued.id, draft.id])  // server order, no sorting
        #expect(store.activeJob(for: queued)?.id == "j_a337003622c0")
        #expect(store.activeJob(for: draft) == nil)
        #expect(h.server.count("GET", "/api/jobs/j_a337003622c0") == 1)
        #expect(store.hasActiveGames)
        #expect(store.refreshNote == GamesStore.updatingNote)
        #expect(store.hasLoaded)
        #expect(store.error == nil)
    }

    @Test func aJobThatCannotBeLoadedIsIgnored() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", try SessionFixtures.reply([try queuedGame()]))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .html(502))
        let store = GamesStore(session: h.session)

        await store.refresh()

        #expect(store.games.count == 1)
        #expect(store.latestJobs.isEmpty)  // "Waiting for the worker…"
        #expect(store.error == nil)
    }

    @Test func aFailedLoadKeepsTheList() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .fixture("games_list.json"), .html(503))
        let store = GamesStore(session: h.session)

        await store.refresh()
        let loaded = store.games
        await store.refresh()

        #expect(store.games == loaded)
        #expect(store.error?.title == "Server unavailable")
        #expect(store.error?.isRetryable == true)
        #expect(h.session.isSignedIn)
    }

    @Test func a401TripsTheGateAndShowsNothing() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .json(401, try Fixture.data("err_401_wrong_password.json")))
        let store = GamesStore(session: h.session)

        await store.refresh()

        #expect(store.error == nil)
        #expect(!h.session.isSignedIn)
    }

    @Test func upsertReplacesOrPutsANewGameFirst() async throws {
        let store = GamesStore.preview(games: [try SessionFixtures.game("game_ready.json")])
        let changed = try SessionFixtures.game("game_ready.json") { $0.location = "Test Gym 2" }
        store.upsert(changed)
        #expect(store.games.count == 1)
        #expect(store.games.first?.location == "Test Gym 2")

        let new = try SessionFixtures.game("game_get.json") { $0.id = "g_000000000b02" }
        store.upsert(new)
        #expect(store.games.map(\.id) == ["g_000000000b02", "g_e934f8c21058"])
    }

    @Test func deleteRemovesTheGameAndTreatsAMissingOneAsGone() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let ready = try SessionFixtures.game("game_ready.json")
        let other = try SessionFixtures.game("game_get.json") { $0.id = "g_000000000b03" }
        h.server.on("GET", "/api/games", try SessionFixtures.reply([ready, other]), try SessionFixtures.reply([other]), try SessionFixtures.reply([Game]()))
        h.server.on("DELETE", "/api/games/\(ready.id)", .empty(204))
        h.server.on("DELETE", "/api/games/\(other.id)", .fixture("err_404_game_delete_again.json", status: 404))
        let store = GamesStore(session: h.session)
        var deleted: [String] = []
        store.didDelete = { deleted.append($0) }
        await store.refresh()

        try await store.delete(ready.id)
        #expect(store.games.map(\.id) == [other.id])
        try await store.delete(other.id)  // already gone elsewhere: not an error
        #expect(store.games.isEmpty)
        #expect(deleted == [ready.id, other.id])
    }

    @Test func otherDeleteErrorsAreThrown() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("DELETE", "/api/games/g_e934f8c21058", .html(502))
        let store = GamesStore(session: h.session)

        await #expect(throws: APIError.self) {
            try await store.delete("g_e934f8c21058")
        }
    }

    // MARK: - Polling (07 §6 loop 1)

    @Test func pollingRepeatsEvery5SecondsWhileAGameIsActiveThenWaits() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let active = try SessionFixtures.reply([try queuedGame()])
        let idle = try SessionFixtures.reply([try SessionFixtures.game("game_ready.json")])
        h.server.on("GET", "/api/games", active, active, idle)
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_1_queued_queued.json"))
        let sleeper = RecordingSleeper()
        let store = GamesStore(session: h.session)

        let polling = Task { await store.poll(sleeper: sleeper.sleeper) }
        try await waitUntil("three loads") { h.server.count("GET", "/api/games") >= 3 && !store.isLoading }
        try await Task.sleep(for: .milliseconds(30))

        #expect(h.server.count("GET", "/api/games") == 3)  // idle now: no more loads
        #expect(sleeper.recorded == [.seconds(5), .seconds(5)])

        // A game becomes active (started on this device): polling continues.
        store.upsert(try queuedGame())
        try await waitUntil("polling to continue") { h.server.count("GET", "/api/games") >= 4 }
        polling.cancel()
        await polling.value
    }

    @Test func aRetryableErrorIsTriedAgainIn10Seconds() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .html(502), .fixture("games_list.json"))
        let sleeper = RecordingSleeper()
        let store = GamesStore(session: h.session)

        let polling = Task { await store.poll(sleeper: sleeper.sleeper) }
        try await waitUntil("the retry") { h.server.count("GET", "/api/games") >= 2 && !store.isLoading }
        #expect(sleeper.recorded == [.seconds(10)])
        #expect(store.error == nil)
        polling.cancel()
        await polling.value
    }

    @Test func anErrorThatIsNotRetryableStopsPolling() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", SessionFixtures.error(400, code: "VALIDATION_FAILED", title: "Invalid input", message: "Bad Request"))
        let sleeper = RecordingSleeper()
        let store = GamesStore(session: h.session)

        let polling = Task { await store.poll(sleeper: sleeper.sleeper) }
        try await waitUntil("the error") { store.error != nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.server.count("GET", "/api/games") == 1)
        #expect(sleeper.recorded.isEmpty)
        polling.cancel()
        await polling.value
    }

    /// Several windows share the store: a second list's `poll()` joins the running loop (no second loop that
    /// would load twice as often), takes over when the first list goes away, and a waiting list that goes away
    /// leaves without loading anything.
    @Test func windowsShareOnePollingLoop() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", try SessionFixtures.reply([try queuedGame()]))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_1_queued_queued.json"))
        let store = GamesStore(session: h.session)
        let firstSleeper = BlockingSleeper()

        let first = Task { await store.poll(sleeper: firstSleeper.sleeper) }
        try await waitUntil("the first load") { h.server.count("GET", "/api/games") == 1 && !store.isLoading }
        let second = Task { await store.poll(sleeper: BlockingSleeper().sleeper) }
        let third = Task { await store.poll(sleeper: BlockingSleeper().sleeper) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.server.count("GET", "/api/games") == 1)  // one loop for every window

        third.cancel()
        await third.value  // a window that goes away while waiting just leaves
        #expect(h.server.count("GET", "/api/games") == 1)

        first.cancel()
        await first.value
        #expect(firstSleeper.wasCancelled)
        try await waitUntil("the second window's loop") { h.server.count("GET", "/api/games") == 2 && !store.isLoading }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.server.count("GET", "/api/games") == 2)
        second.cancel()
        await second.value
    }

    @Test func pollingEndsWhenTheSessionStops() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.on("GET", "/api/games", .fixture("games_list.json"))
        let store = GamesStore(session: h.session)

        let polling = Task { await store.poll(sleeper: RecordingSleeper().sleeper) }
        try await waitUntil("the first load") { store.hasLoaded }
        h.session.signOut()
        await polling.value  // returns without being cancelled
        #expect(!polling.isCancelled)
    }
}
