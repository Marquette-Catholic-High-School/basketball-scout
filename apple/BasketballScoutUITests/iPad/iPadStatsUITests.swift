import XCTest

/// Box score, shot chart, plays and data quality on iPad (06 §9–§12), in the stacked page layout (landscape
/// with the sidebar shown, where the tabs get about 840 points of width).
final class iPadStatsUITests: XCTestCase {
    @MainActor
    private func openTab(_ tab: String, _ driver: ScoutAppDriver, team: String) async throws -> String {
        let film = try ScoutUITestFilm.url()
        let id = try await driver.api.iPadAnalysedGame(scoutedTeam: team, film: film, otherTeam: "Test Rivals")
        driver.iPadLaunch(self)
        driver.iPadOpenGame("\(team) vs Test Rivals")
        XCTAssertTrue(driver.app.buttons[tab].waitForExistence(timeout: 30), "no \(tab) tab")
        driver.iPadScrollPage(by: 500)
        driver.iPadSelectTab(tab)
        return id
    }

    @MainActor
    func testBoxScoreShowsTheTeamsAndJerseyNumbers() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Box score", driver, team: "Test Box Bulls")
        addTeardownBlock { await api.deleteGame(id) }
        let table = app.scrollViews["Test Box Bulls box score"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "no box score table")
        // One switch segment per team, scouted first (06 §9).
        XCTAssertTrue(app.buttons["Test Box Bulls"].exists)
        XCTAssertTrue(app.buttons["Test Rivals"].exists)
        for column in ["Player", "Minutes", "Points", "Field goals", "Plus-minus"] {
            XCTAssertTrue(table.buttons[column].exists, "no \(column) column")
        }
        driver.expectText("Totals")
        driver.expectText("MIN is approximate on-floor video time")
        driver.iPadScrollPage(by: 250)
        driver.snapshot("box score L")
        let jersey = table.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'number '")).firstMatch
        XCTAssertTrue(jersey.exists, "no jersey numbers in the table")
        iPadKnownBug("bug: the # column of the iPad box score table is placed left of the table and cannot be seen") {
            XCTAssertGreaterThanOrEqual(jersey.frame.minX, table.frame.minX, "the jersey column is outside the table")
        }

        // The other team's box.
        app.buttons["Test Rivals"].firstMatch.tap()
        XCTAssertTrue(app.scrollViews["Test Rivals box score"].waitForExistence(timeout: 10), "the team switch did nothing")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testPlaysTablesShowEveryColumn() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Plays", driver, team: "Test Plays Bulls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("% Poss is the share of that team's possessions with the play.")
        driver.iPadScrollPage(by: 200)
        driver.snapshot("plays L")
        let card = app.otherElements["Plays"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let offenses = app.staticTexts.matching(NSPredicate(format: "label == 'Offense'")).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
        let turnovers = app.staticTexts.matching(NSPredicate(format: "label == 'TO'")).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(offenses.count, 2, "expected one Offense table per team")
        XCTAssertGreaterThanOrEqual(turnovers.count, 2, "no TO columns")
        if offenses.count == 2, let leftTO = turnovers.first, let rightTO = turnovers.last {
            iPadKnownBug("bug: in an 840-point card the two teams' play tables overlap and the TO columns are cut off") {
                XCTAssertLessThanOrEqual(leftTO.frame.maxX, offenses[1].frame.minX, "the left table runs under the right one")
                XCTAssertLessThanOrEqual(rightTO.frame.maxX, card.frame.maxX, "the right table's TO column is cut off")
            }
        }
        driver.expectText("Individual plays")
        XCTAssertTrue(app.buttons["Possessions"].exists)
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testShotChartTeamFilterChangesTheZoneTable() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Shot chart", driver, team: "Test Shots Bulls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("By zone")
        driver.expectText("All shots")
        driver.expectText("Dot = made, × = missed.")
        driver.snapshot("shot chart L")
        // The zone table's last row reads "All shots: <made> of <attempts>, <pct>, 100% of the shots".
        let allShots = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'All shots:'")).firstMatch
        XCTAssertTrue(allShots.exists, "no All shots row")
        let before = allShots.label
        // The chart's Team filter (the timeline above has its own "Team, All teams"). The app remembers the last
        // choice across games (F-Stats, 09 R46), so it may start on any of the three.
        let team = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Team, ' AND label != 'Team, All teams'")).firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 5), "no Team filter on the chart")
        let other = team.label.hasSuffix("Both teams") ? "Test Shots Bulls" : "Both teams"
        team.tap()
        driver.iPadWait(1)
        let choice = app.buttons[other].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(other) choice")
        choice.tap()
        driver.iPadWait(1.5)
        XCTAssertNotEqual(allShots.label, before, "the zone table did not change with the team filter")
        driver.snapshot("other team choice L")
        // Leave the chart on the scouted team (the default) for the next run.
        if other != "Test Shots Bulls" {
            team.tap()
            driver.iPadWait(1)
            let scouted = app.buttons["Test Shots Bulls"].firstMatch
            if scouted.waitForExistence(timeout: 5) { scouted.tap() }
        }
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testDataQualityListsTheFacts() async throws {
        let driver = try ScoutAppDriver(self)
        let api = driver.api
        let id = try await openTab("Data quality", driver, team: "Test Quality Bulls")
        addTeardownBlock { await api.deleteGame(id) }
        for fact in ["Court mapped", "Coordinates", "Jersey match rate", "Tracks assigned", "Ball visible",
                     "Average event confidence", "Film", "Pipeline"] {
            driver.expectText(fact)
        }
        driver.expectText("Jerseys not on a roster")
        driver.expectText("Warnings from the analysis")
        driver.snapshot("data quality L")
        driver.iPadRotate(.portrait)
    }
}
