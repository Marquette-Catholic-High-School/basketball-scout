#if os(iOS)
import XCTest

/// The games list on iPhone (07 §3, 03 §7.1): rows in each status, a running analysis, search, the row
/// actions (context menu, swipes, "Add film"), delete, pull to refresh, the System status row and panel,
/// Settings.
final class iPhoneGamesListTests: XCTestCase {
    /// Rows of a game without film, with film not analysed yet, and analysed: the web's badges and meta
    /// lines (07 §3.4–§3.5), newest first.
    @MainActor
    func testRowsShowEachStatus() async throws {
        let kit = try iPhoneKit(self, tag: "rows")
        let api = kit.api
        let tag = Int.random(in: 100...999)
        let draft = try await api.iPhoneCreateGame(team: "iPT Draft \(tag)", level: "Varsity", date: "2026-11-07", location: "Test Gym")
        addTeardownBlock { await api.deleteGame(draft) }
        let uploaded = try await api.iPhoneCreateGame(team: "iPT Uploaded \(tag)", level: "Freshman")
        addTeardownBlock { await api.deleteGame(uploaded) }
        try await api.iPhoneUploadFilm(gameID: uploaded, film: ScoutUITestFilm.url(), autoStart: false)
        let ready = try await api.iPhoneAnalysedGame(team: "iPT Ready \(tag)", date: "2026-11-01", location: "Test Arena")
        addTeardownBlock { await api.deleteGame(ready) }

        kit.launchSignedIn()
        let readyRow = kit.gameRow("iPT Ready \(tag) vs Test Opponent")
        XCTAssertTrue(kit.wait(readyRow, 20), "the analysed game is not listed")
        kit.shot("rows")
        XCTAssertTrue(readyRow.staticTexts["Ready"].exists, "no Ready badge")
        XCTAssertTrue(readyRow.staticTexts["Nov 1, 2026 · Varsity · Test Arena"].exists, "date · level · location missing")
        XCTAssertTrue(readyRow.staticTexts["Film: \(try ScoutUITestFilm.url().lastPathComponent)"].exists, "film name missing")

        let uploadedRow = kit.gameRow("iPT Uploaded \(tag) vs Test Opponent")
        XCTAssertTrue(uploadedRow.exists)
        XCTAssertTrue(uploadedRow.staticTexts["Film uploaded"].exists, "no Film uploaded badge")
        XCTAssertFalse(uploadedRow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add film'")).firstMatch.exists,
                       "a game with film offers Add film")
        // Newest created first (07 §3.3).
        XCTAssertLessThan(readyRow.frame.minY, uploadedRow.frame.minY, "the list is not newest first")

        let draftRow = kit.gameRow("iPT Draft \(tag) vs Test Opponent")
        kit.scrollIntoView(draftRow)
        XCTAssertTrue(draftRow.staticTexts["No film"].exists, "no No film badge")
        XCTAssertTrue(draftRow.staticTexts["Nov 7, 2026 · Varsity · Test Gym"].exists)
        XCTAssertTrue(draftRow.buttons["Add film to iPT Draft \(tag) vs Test Opponent"].exists, "no Add film button")
        kit.shot("draft-row")
    }

    /// While an analysis runs the row shows the job's badge, the progress line and the refresh note, then
    /// "Ready" again by itself (5 s polling, 07 §6 loop 1).
    @MainActor
    func testRunningAnalysisShowsProgress() async throws {
        let kit = try iPhoneKit(self, tag: "running")
        let api = kit.api
        let team = "iPT Running \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        let row = kit.gameRow("\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(row, 20))

        try await api.iPhoneStartJob(gameID, kind: "analyze")
        // An idle list does not poll: pull to refresh finds the queued job, then the list polls every 5 s.
        kit.pullToRefresh()
        let running = row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Processing' OR label == 'Queued'")).firstMatch
        XCTAssertTrue(kit.wait(running, 15), "no Queued / Processing badge while the analysis runs")
        kit.shot("running")
        let progress = row.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'Analyzing on the GPU' OR label CONTAINS 'Waiting for the' OR label CONTAINS 'Preparing' OR label CONTAINS 'Building box score' OR label CONTAINS 'Downloading results' OR label CONTAINS 'Uploading film'"
        )).firstMatch
        XCTAssertTrue(progress.exists, "no progress line under the running game")
        // (The "Updating every 5 seconds while film is processing" note is the list's footer, after the last
        // game: off screen with a full list, so it is not checked here.)
        XCTAssertTrue(kit.wait(row.staticTexts["Ready"], 60), "the row did not return to Ready after the analysis")
        kit.shot("finished")
    }

    /// Search matches the team names (scouted and opponent); no match shows the system's empty search.
    @MainActor
    func testSearchFindsGamesByTeamName() async throws {
        let kit = try iPhoneKit(self, tag: "search")
        let api = kit.api
        let tag = Int.random(in: 100...999)
        let first = try await api.iPhoneCreateGame(team: "iPT Search Alpha \(tag)")
        addTeardownBlock { await api.deleteGame(first) }
        let second = try await api.iPhoneCreateGame(team: "iPT Search Beta \(tag)", other: "Test Zebras \(tag)")
        addTeardownBlock { await api.deleteGame(second) }
        kit.launchSignedIn()
        let search = kit.app.searchFields["Team name"].firstMatch
        XCTAssertTrue(kit.wait(search))
        search.tap()
        search.typeText("alpha \(tag)")
        XCTAssertTrue(kit.wait(kit.gameRow("iPT Search Alpha \(tag)"), 5), "search is not case-insensitive")
        XCTAssertFalse(kit.gameRow("iPT Search Beta \(tag)").exists, "search did not filter")
        kit.shot("alpha")
        kit.type("zebras \(tag)", into: search)
        XCTAssertTrue(kit.wait(kit.gameRow("iPT Search Beta \(tag)"), 5), "search does not match the opponent")
        kit.type("zebras \(tag) nothing like it", into: search)
        XCTAssertTrue(kit.wait(kit.any("No Results for"), 5), "no empty search result")
        kit.shot("no-results")
        kit.tap(kit.app.buttons["close"].firstMatch)
        XCTAssertTrue(kit.wait(kit.gameRow("iPT Search Alpha \(tag)"), 5), "closing the search did not show every game")
    }

    /// The context menu has the web card's actions; Delete asks the web's question first (Cancel keeps the
    /// game), then removes the game and confirms with a toast (07 §3.7).
    @MainActor
    func testContextMenuDeleteAsksFirst() async throws {
        let kit = try iPhoneKit(self, tag: "delete")
        let api = kit.api
        let team = "iPT Delete \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        let title = "\(team) vs Test Opponent"
        let row = kit.gameRow(title)
        XCTAssertTrue(kit.wait(row, 20))
        row.press(forDuration: 1.2)
        for item in ["Open", "Roster", "Add film", "Delete"] {
            XCTAssertTrue(kit.wait(kit.app.buttons[item].firstMatch, 3), "context menu lacks \(item)")
        }
        kit.shot("context-menu")
        kit.app.buttons["Delete"].firstMatch.tap()
        let alert = kit.app.alerts.firstMatch
        XCTAssertTrue(kit.wait(alert, 5), "no confirmation before deleting")
        XCTAssertTrue(alert.staticTexts["Delete \"\(title)\"?"].exists, "the question does not name the game")
        XCTAssertTrue(alert.staticTexts["This removes the film, analysis, rosters and reports for this game. It cannot be undone."].exists)
        kit.shot("question")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(kit.waitGone(alert, 5))
        XCTAssertTrue(row.exists, "Cancel deleted the game")

        row.press(forDuration: 1.2)
        kit.tap(kit.app.buttons["Delete"].firstMatch)
        kit.tap(kit.alertButton("Delete"))
        XCTAssertTrue(kit.wait(kit.any("Deleted \(title)"), 5), "no toast after deleting")
        kit.shot("deleted")
        XCTAssertTrue(kit.waitGone(row, 10), "the deleted game is still listed")
        let left = try await api.iPhoneGames().contains { ($0["id"] as? String) == gameID }
        XCTAssertFalse(left, "the server still has the game")
    }

    /// The trailing swipe deletes (with the same question); the leading swipe offers Roster and Add film.
    @MainActor
    func testSwipeActions() async throws {
        let kit = try iPhoneKit(self, tag: "swipe")
        let api = kit.api
        let team = "iPT Swipe \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        let row = kit.gameRow("\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(row, 20))
        row.swipeRight()
        XCTAssertTrue(kit.wait(kit.app.buttons["Roster"].firstMatch, 3), "no Roster swipe action")
        XCTAssertTrue(kit.app.buttons["Add film"].firstMatch.exists, "no Add film swipe action")
        kit.shot("leading")
        row.swipeLeft()   // closes the leading actions
        if !kit.app.buttons["Delete"].firstMatch.waitForExistence(timeout: 1.5) { row.swipeLeft() }
        XCTAssertTrue(kit.wait(kit.app.buttons["Delete"].firstMatch, 3), "no Delete swipe action")
        kit.shot("trailing")
        kit.app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(kit.wait(kit.app.alerts.firstMatch, 5), "the swipe deletes without asking")
        kit.alertButton("Cancel").tap()
        XCTAssertTrue(row.exists)
    }

    /// The row's "Add film" button and the menu's "Roster" open that screen of the game (index.js:76-80:
    /// "/upload?game=<id>", "/games/<id>/roster"). On iPhone they open the game page instead.
    @MainActor
    func testRowActionsOpenTheirScreen() async throws {
        let kit = try iPhoneKit(self, tag: "row-actions")
        let api = kit.api
        let team = "iPT Row Actions \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        let title = "\(team) vs Test Opponent"
        kit.tap(kit.app.buttons["Add film to \(title)"])
        XCTAssertTrue(kit.wait(kit.app.navigationBars.buttons["Games"].firstMatch, 10), "the game did not open")
        kit.pause(1)
        kit.shot("after-add-film")
        kit.expectBug("bug: the games list's Add film opens the game page, not the film screen (the route is pushed before GameView registers its destinations)") {
            XCTAssertTrue(kit.wait(kit.button("Choose from Photos"), 4), "Add film did not open the film screen")
        }
        kit.back()
        if !kit.driver.gamesList.waitForExistence(timeout: 3) { kit.back() }
        let row = kit.gameRow(title)
        XCTAssertTrue(kit.wait(row, 10))
        row.press(forDuration: 1.2)
        kit.tap(kit.app.buttons["Roster"].firstMatch)
        XCTAssertTrue(kit.wait(kit.app.navigationBars.buttons["Games"].firstMatch, 10), "the game did not open")
        kit.pause(1)
        kit.shot("after-roster")
        kit.expectBug("bug: the games list's Roster opens the game page, not the roster") {
            XCTAssertTrue(kit.wait(kit.app.navigationBars["Rosters & jerseys"], 4), "Roster did not open the roster page")
        }
    }

    /// A game added on another device appears after pull to refresh (an idle list does not poll).
    @MainActor
    func testPullToRefreshShowsNewGames() async throws {
        let kit = try iPhoneKit(self, tag: "refresh")
        let api = kit.api
        kit.launchSignedIn()
        let team = "iPT Refresh \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let row = kit.gameRow("\(team) vs Test Opponent")
        XCTAssertFalse(row.waitForExistence(timeout: 2), "an idle list reloaded by itself")
        kit.pullToRefresh()
        XCTAssertTrue(kit.wait(row, 10), "pull to refresh did not load the new game")
        kit.shot("refreshed")
    }

    /// The System status row names the most serious warning and opens the panel with every warning, the
    /// grid and "Check again"; the toolbar button opens the same panel; Settings shows the server.
    @MainActor
    func testSystemStatusAndSettings() async throws {
        let kit = try iPhoneKit(self, tag: "status")
        let app = kit.app
        let health = try await kit.api.iPhoneHealth()
        kit.launchSignedIn()
        if (health["claude_configured"] as? Bool) == false {
            // The test server runs the mock processor without Claude (and here without ffmpeg).
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'System status.'")).firstMatch
            XCTAssertTrue(kit.wait(row, 10), "no System status row although the server has warnings")
            XCTAssertTrue(row.label.contains("Claude is not configured, so scouting reports can't be written."), row.label)
            row.tap()
            XCTAssertTrue(kit.wait(app.navigationBars["System status"], 5))
            for label in ["Overall", "Version", "Video processor", "Job queue", "Modal (GPU)", "Claude reports", "Worker last seen", "ffmpeg"] {
                XCTAssertTrue(kit.any(label).exists, "panel lacks \(label)")
            }
            XCTAssertTrue(kit.any("Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.").exists)
            kit.shot("panel")
            kit.tap(kit.button("Check again"))
            XCTAssertTrue(kit.wait(kit.any("Checked just now"), 10))
            kit.tap(kit.button("Done"))
        }
        kit.tap(app.navigationBars.buttons["System status"])
        XCTAssertTrue(kit.wait(app.navigationBars["System status"], 5), "the toolbar button does not open System status")
        kit.tap(kit.button("Done"))
        kit.tap(app.navigationBars.buttons["Settings"])
        XCTAssertTrue(kit.wait(app.navigationBars["Settings"], 5))
        XCTAssertTrue(kit.any(kit.driver.server.origin).exists, "Settings does not show the server")
        XCTAssertTrue(kit.any(kit.driver.server.username).exists, "Settings does not show the username")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).firstMatch.exists)
        kit.shot("settings")
        kit.tap(kit.button("Done"))
        XCTAssertTrue(kit.wait(kit.driver.gamesList, 5))
    }

    /// With no games on the server the list explains the app and offers "Scout your first opponent", which
    /// opens New game (web index.js:49-50). Runs only against an empty server (it never deletes games it did
    /// not make).
    @MainActor
    func testEmptyListOffersFirstGame() async throws {
        let kit = try iPhoneKit(self, tag: "empty")
        let app = kit.app
        let games = try await kit.api.iPhoneGames()
        try XCTSkipUnless(games.isEmpty, "The server has \(games.count) games; the empty list shows only on an empty server.")
        kit.launchSignedIn()
        XCTAssertTrue(kit.wait(kit.any("No games yet."), 15), "no empty state")
        XCTAssertTrue(kit.any("Upload opponent film, then review the timeline, box score, plays and scouting report.").exists)
        kit.shot("empty")
        kit.tapButton("Scout your first opponent")
        XCTAssertTrue(kit.wait(app.navigationBars["New game"], 5), "Scout your first opponent does not open New game")
        kit.tapButton("Cancel")
        XCTAssertTrue(kit.wait(kit.any("No games yet."), 5))
    }
}
#endif
