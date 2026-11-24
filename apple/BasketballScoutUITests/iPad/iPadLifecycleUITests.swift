import XCTest

/// Background, foreground and relaunch (09 R29: the app checks the server again on return and keeps the
/// game open; a relaunch signs in again with the saved password).
final class iPadLifecycleUITests: XCTestCase {
    @MainActor
    func testBackgroundThenForegroundKeepsTheGameOpen() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Life Wrens", film: film, otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Life Wrens vs Test Rivals")
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 20))
        XCUIDevice.shared.press(.home)
        driver.iPadWait(3)
        XCTAssertEqual(app.state, .runningBackground)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // Still signed in, the same game on screen, its tabs back.
        XCTAssertTrue(app.staticTexts["Test Life Wrens vs Test Rivals"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["Server address"].exists, "the app signed out in the background")
        driver.snapshot("after foreground L")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testRelaunchStaysSignedIn() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Relaunch Rooks", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        XCTAssertTrue(driver.iPadGameRow("Test Relaunch Rooks").waitForExistence(timeout: 20))
        app.terminate()
        app.launch()
        // Straight to the games list: no sign-in screen, no result sheet.
        let games = driver.gamesList
        let appeared = driver.waitForAny([games, app.textFields["Server address"]], timeout: 30)
        XCTAssertTrue(appeared === games, "the app did not open on the games list after a relaunch")
        XCTAssertTrue(driver.iPadGameRow("Test Relaunch Rooks").waitForExistence(timeout: 20))
        XCTAssertFalse(app.navigationBars["Connected"].exists, "the sign-in result sheet came back on relaunch")
        driver.snapshot("relaunched L")
        driver.iPadRotate(.portrait)
    }
}
