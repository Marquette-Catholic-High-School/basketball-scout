import XCTest

/// The games list in the iPad sidebar (07 §3, 03 §7.1): rows, search, context menu, delete, System status,
/// sidebar and refresh.
final class iPadGamesListUITests: XCTestCase {
    /// Deletes every game first: the iPad test server is a throwaway server that holds only test data.
    @MainActor
    func testEmptyListOffersTheFirstGame() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        await driver.api.iPadDeleteAllGames()
        driver.iPadLaunch(self)
        driver.expectText("No games yet.")
        driver.expectText("Upload opponent film, then review the timeline, box score, plays and scouting report.")
        driver.snapshot("empty list L")
        app.buttons["Scout your first opponent"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New game"].waitForExistence(timeout: 10), "the New game sheet did not open")
        driver.tapButton("Cancel")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testRowsShowStatusAndDetails() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let draft = try await api.createGame(scoutedTeam: "Test Draft Eagles", otherTeam: "Test Hawks")
        let uploaded = try await api.iPadUploadedGame(scoutedTeam: "Test Uploaded Owls", film: film)
        let titled = try await api.createGame(scoutedTeam: "Test Titled Wolves", otherTeam: "Test Rival", level: "JV")
        try await api.iPadPatchGame(titled, ["title": "Test Custom Title", "game_date": "2026-11-07", "location": "Test Gym"])
        let ready = try await api.iPadAnalysedGame(scoutedTeam: "Test Ready Bears", film: film)
        addTeardownBlock {
            for id in [draft, uploaded, titled, ready] { await api.deleteGame(id) }
        }
        driver.iPadLaunch(self)

        let draftRow = driver.iPadGameRow("Test Draft Eagles vs Test Hawks")
        XCTAssertTrue(draftRow.waitForExistence(timeout: 20))
        XCTAssertTrue(draftRow.staticTexts["No film"].exists)
        XCTAssertTrue(app.buttons["Add film to Test Draft Eagles vs Test Hawks"].exists, "no Add film in a row without film")

        let uploadedRow = driver.iPadGameRow("Test Uploaded Owls vs Test Opponent")
        XCTAssertTrue(uploadedRow.staticTexts["Film uploaded"].exists)
        XCTAssertTrue(uploadedRow.staticTexts["Film: uitest-film.mp4"].exists)
        XCTAssertFalse(app.buttons["Add film to Test Uploaded Owls vs Test Opponent"].exists)

        let readyRow = driver.iPadGameRow("Test Ready Bears vs Test Opponent")
        XCTAssertTrue(readyRow.staticTexts["Ready"].exists)

        // A custom title shows the matchup under it, then date · level · location.
        let titledRow = driver.iPadGameRow("Test Custom Title")
        XCTAssertTrue(titledRow.staticTexts["Test Titled Wolves vs Test Rival"].exists)
        XCTAssertTrue(titledRow.staticTexts["Nov 7, 2026 · JV · Test Gym"].exists)

        // Newest created first (07 §3.3).
        let order = [readyRow, titledRow, uploadedRow, draftRow].map(\.frame.minY)
        XCTAssertEqual(order, order.sorted(), "rows are not newest first")
        driver.snapshot("rows L")
        driver.iPadRotate(.portrait)
        driver.snapshot("rows portrait")
    }

    @MainActor
    func testSearchFindsTeamsAndSaysWhenNothingMatches() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let bears = try await api.createGame(scoutedTeam: "Test Search Bears", otherTeam: "Test Rivals")
        let owls = try await api.createGame(scoutedTeam: "Test Search Owls", otherTeam: "Test Rivals")
        addTeardownBlock {
            await api.deleteGame(bears)
            await api.deleteGame(owls)
        }
        driver.iPadLaunch(self)
        XCTAssertTrue(driver.iPadGameRow("Test Search Owls").waitForExistence(timeout: 20))
        let search = app.searchFields["Team name"].firstMatch
        search.tap()
        search.typeText("bears")
        XCTAssertTrue(driver.iPadGameRow("Test Search Bears").waitForExistence(timeout: 5))
        XCTAssertTrue(driver.iPadWaitGone(driver.iPadGameRow("Test Search Owls"), timeout: 5), "the search did not filter")
        driver.snapshot("search bears L")
        search.buttons.firstMatch.tap()
        search.tap()
        search.typeText("zzzz")
        driver.expectText("No Results")
        driver.snapshot("search nothing L")
        search.buttons.firstMatch.tap()
        XCTAssertTrue(driver.iPadGameRow("Test Search Owls").waitForExistence(timeout: 5))
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testDeleteFromTheContextMenuAsksFirst() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Delete Cranes", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        let row = driver.iPadGameRow("Test Delete Cranes vs Test Rivals")
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        // The web card's actions, in its order.
        driver.iPadContextMenu(row)
        for title in ["Open", "Roster", "Add film", "Delete"] {
            XCTAssertTrue(app.buttons[title].exists, "no \(title) in the context menu")
        }
        driver.snapshot("context menu L")
        app.buttons["Delete"].firstMatch.tap()
        driver.expectText("Delete \"Test Delete Cranes vs Test Rivals\"?")
        driver.expectText("This removes the film, analysis, rosters and reports for this game. It cannot be undone.")
        driver.snapshot("delete question L")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(row.exists, "Cancel deleted the game")

        driver.iPadContextMenu(row)
        app.buttons["Delete"].firstMatch.tap()
        app.alerts.buttons["Delete"].firstMatch.tap()
        driver.expectText("Deleted Test Delete Cranes vs Test Rivals", timeout: 10)
        driver.snapshot("deleted L")
        XCTAssertTrue(driver.iPadWaitGone(row, timeout: 10), "the deleted game is still listed")
        do {
            _ = try await api.iPadGame(id)
            XCTFail("the game still exists on the server")
        } catch {}
        driver.iPadRotate(.portrait)
    }

    /// The handoff asked integration to check this (F-Games "Integration must check" 1).
    @MainActor
    func testContextMenuRosterOpensTheRosterPage() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Menu Herons", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        let row = driver.iPadGameRow("Test Menu Herons vs Test Rivals")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        driver.iPadContextMenu(row)
        driver.tapButton("Roster")
        XCTAssertTrue(app.staticTexts["Test Menu Herons vs Test Rivals"].waitForExistence(timeout: 10), "the game did not open")
        driver.iPadWait(2)
        driver.snapshot("after Roster from the menu L")
        iPadKnownBug("bug: Roster from the context menu of a game that is not open shows the game page, not the roster") {
            XCTAssertTrue(app.navigationBars["Rosters & jerseys"].exists, "the roster page did not open")
        }
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testSystemStatusRowOpensThePanel() throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        driver.iPadLaunch(self)
        // The demo server has warnings: Claude and ffmpeg are missing, and it runs the mock processor.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'System status.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no System status row")
        XCTAssertTrue(row.label.contains("Claude is not configured, so scouting reports can't be written."))
        XCTAssertTrue(row.label.contains("2 more notices"))
        row.tap()
        driver.expectText("Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.")
        driver.expectText("ffmpeg is not installed on the server, so uploaded film can't be checked before processing.")
        for fact in ["Overall, OK", "Version, 0.1.0", "Video processor, mock", "Job queue, sqlite OK", "Claude reports, Not configured", "ffmpeg, Missing"] {
            XCTAssertTrue(app.staticTexts[fact].exists, "no \(fact)")
        }
        driver.snapshot("status panel L")
        driver.tapButton("Done")
        // The toolbar button opens the same panel.
        driver.tapButton("System status")
        driver.expectText("Overall, OK")
        driver.tapButton("Done")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testSidebarHidesAndShowsInBothOrientations() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Sidebar Kites", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Sidebar Kites vs Test Rivals")
        driver.tapButton("Hide Sidebar")
        XCTAssertTrue(driver.iPadWaitGone(app.searchFields["Team name"], timeout: 5) || !app.searchFields["Team name"].isHittable,
                      "the sidebar did not hide")
        driver.snapshot("sidebar hidden L")
        driver.tapButton("Show Sidebar")
        XCTAssertTrue(app.searchFields["Team name"].waitForExistence(timeout: 5))
        driver.iPadRotate(.portrait)
        XCTAssertTrue(driver.gamesList.exists)
        XCTAssertTrue(app.staticTexts["Test Sidebar Kites vs Test Rivals"].exists)
        driver.snapshot("portrait with sidebar")
    }

    /// The list is not polled while nothing is processing (07 §6); pull to refresh shows games added elsewhere.
    @MainActor
    func testPullToRefreshShowsGamesAddedElsewhere() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        driver.iPadLaunch(self)
        let id = try await api.createGame(scoutedTeam: "Test Pull Doves", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        let row = driver.iPadGameRow("Test Pull Doves vs Test Rivals")
        XCTAssertFalse(row.exists)
        let list = app.collectionViews["Sidebar"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "pull to refresh did not load the new game")
        driver.iPadRotate(.portrait)
    }
}
