import XCTest

/// The first check: the app signs in to the test server and shows a game with analysed film.
final class SmokeUITests: XCTestCase {
    @MainActor
    func testSignInShowsTheGamesList() throws {
        let driver = try ScoutAppDriver(self)
        driver.launchSignedIn()
        driver.snapshot("games list")
    }

    @MainActor
    func testAnalysedGameOpensWithResults() async throws {
        let driver = try ScoutAppDriver(self)
        let team = "Smoke Test \(Int.random(in: 100...999))"
        let gameID = try await driver.analysedGame(scoutedTeam: team)
        let api = driver.api
        addTeardownBlock { await api.deleteGame(gameID) }

        driver.launchSignedIn()
        let row = driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", team)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the new game is not in the list")
        driver.snapshot("list with game")
        row.tap()
        driver.expectText("Box score", timeout: 30)
        driver.snapshot("game page")
    }
}
