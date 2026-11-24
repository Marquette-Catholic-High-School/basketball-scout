import XCTest

/// Dark mode and the largest text size on the main iPad screens (07 §8, §10). These tests take screenshots
/// for review and check that the main controls are still there; the look itself is judged by a person.
final class iPadAppearanceUITests: XCTestCase {
    @MainActor
    func testDarkModeMainScreens() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Dark Swans", film: film, otherTeam: "Test Rivals")
        let draft = try await api.createGame(scoutedTeam: "Test Dark Draft", otherTeam: "Test Rivals")
        addTeardownBlock {
            await api.deleteGame(id)
            await api.deleteGame(draft)
        }
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.appearance = .dark
        driver.iPadLaunch(self)
        driver.snapshot("dark list L")
        driver.iPadOpenGame("Test Dark Swans vs Test Rivals")
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 30))
        driver.snapshot("dark game L")
        driver.iPadScrollPage(by: 600)
        driver.snapshot("dark tabs L")
        driver.tapButton("Roster & jerseys")
        XCTAssertTrue(app.navigationBars["Rosters & jerseys"].waitForExistence(timeout: 15))
        driver.snapshot("dark roster L")
        driver.iPadOpenGame("Test Dark Draft vs Test Rivals")
        driver.expectText("No film yet")
        driver.snapshot("dark draft L")
        driver.tapButton("New game")
        XCTAssertTrue(app.navigationBars["New game"].waitForExistence(timeout: 10))
        driver.snapshot("dark new game L")
        driver.tapButton("Cancel")
        driver.iPadRotate(.portrait)
        driver.snapshot("dark portrait")
        XCUIDevice.shared.appearance = .light
    }

    @MainActor
    func testLargestTextSizeMainScreens() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Big Text Swans", film: film, otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        driver.iPadLaunch(self)
        driver.snapshot("largest text list L")
        // The list is long at this size: find the game with the search field.
        let search = app.searchFields["Team name"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Big Text")
        driver.iPadHideKeyboard()
        driver.iPadOpenGame("Test Big Text Swans vs Test Rivals")
        driver.snapshot("largest text game L")
        XCTAssertTrue(app.buttons["Roster & jerseys"].exists)
        driver.iPadScrollPage(by: 700)
        driver.snapshot("largest text page L")
        driver.iPadRotate(.portrait)
        driver.snapshot("largest text portrait")
        driver.tapButton("New game")
        XCTAssertTrue(app.navigationBars["New game"].waitForExistence(timeout: 10))
        driver.snapshot("largest text new game portrait")
        driver.tapButton("Cancel")
    }
}
