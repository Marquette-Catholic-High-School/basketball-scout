import XCTest

/// The game page on iPad (03 §7.3–§7.7): header, toolbar actions and their enable rules, the job panel
/// (stages, Cancel, Start again), Re-run and Full re-analysis, the team banner, and the stacked layout.
final class iPadGamePageUITests: XCTestCase {
    @MainActor
    func testDraftGameShowsHeaderAndNoFilmCard() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Header Owls", otherTeam: "Test Rivals", level: "JV")
        try await api.iPadPatchGame(id, ["game_date": "2026-11-07", "location": "Test Gym"])
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Header Owls vs Test Rivals")
        // Header: chips, date, level, location, status (03 §7.3 row 1).
        let meta = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Test Header Owls versus Test Rivals.'")).firstMatch
        XCTAssertTrue(meta.waitForExistence(timeout: 10), "no header facts")
        for fact in ["Nov 7, 2026", "JV", "Test Gym", "No film"] {
            XCTAssertTrue(meta.label.contains(fact), "the header does not say \(fact): \(meta.label)")
        }
        // No film yet (03 §7.3 row 5).
        driver.expectText("No film yet")
        driver.expectText("Upload the game film (MP4) or give a direct video link to start the analysis.")
        // Actions (03 §7.4): Analyze film is disabled without film; no Full re-analysis.
        XCTAssertTrue(app.buttons["Roster & jerseys"].exists)
        XCTAssertTrue(app.buttons["Add film"].exists)
        let analyze = app.buttons["Analyze film"].firstMatch
        XCTAssertTrue(analyze.exists)
        XCTAssertFalse(analyze.isEnabled, "Analyze film is enabled for a game without film")
        XCTAssertFalse(app.buttons["Full re-analysis"].exists)
        driver.snapshot("draft page L")
        driver.iPadRotate(.portrait)
        driver.snapshot("draft page portrait")
    }

    @MainActor
    func testAnalyzeCancelAndStartAgain() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadUploadedGame(scoutedTeam: "Test Stop Larks", film: film)
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Stop Larks vs Test Opponent")
        driver.expectText("This film hasn't been analyzed yet.")
        driver.expectText("Click Analyze film to send it to the GPU.")
        XCTAssertTrue(driver.iPadWaitEnabled(app.buttons["Analyze film"].firstMatch), "Analyze film is not enabled")

        // The mock GPU stage lasts 8 seconds: cancel at once (no pictures until the answer is sent).
        app.buttons["Analyze film"].firstMatch.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "no job panel")
        XCTAssertTrue(driver.iPadAny("Film analysis in progress").exists, "no job panel title")
        cancel.tap()
        let stop = app.alerts.buttons["Stop job"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Cancel did not ask first")
        // The question matches the stage the app saw last (03 §7.5): normally the first one.
        let stoppable = driver.iPadAny("Stop this job? You can start it again later.")
        let tooLate = driver.iPadAny("Too late to stop the analysis")
        XCTAssertTrue(stoppable.exists || tooLate.exists, "an unexpected cancel question")
        stop.tap()

        // A cancel that reaches the server after the GPU results were installed is too late: the job finishes
        // with a warning (server rule; jobpanel.js:177). Either outcome is right; the test follows it.
        let cancelled = driver.iPadAny("Film analysis was cancelled")
        let late = driver.iPadAny("Film analysis finished with warnings")
        let outcome = driver.waitForAny([cancelled, late], timeout: 40)
        XCTAssertNotNil(outcome, "neither the cancelled notice nor the finished-with-warnings notice appeared")
        if outcome === late {
            driver.expectText("Cancelled after the new GPU results were in place: the analysis was finished.")
            driver.snapshot("cancel came too late L")
            try await api.waitForGame(id, status: ["ready"], timeout: 60)
            XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 30), "the results did not appear")
            driver.iPadRotate(.portrait)
            return
        }
        driver.expectText("Start it again whenever you are ready.")
        driver.snapshot("cancelled L")

        driver.tapButton("Start again")
        driver.expectText("Film analysis in progress")
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 30), "the results did not appear")
        XCTAssertTrue(driver.iPadWaitGone(app.staticTexts["Film analysis was cancelled"], timeout: 10))
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testRerunAndFullReanalysis() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Action Rams", film: film, otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Action Rams vs Test Rivals")
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 20))

        // Re-run analysis: no question, a toast (03 §7.4).
        app.buttons["Re-run analysis"].firstMatch.tap()
        driver.expectText("Re-running the analysis…")
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        let jobsAfterRerun = try await api.iPadJobs(gameID: id).count

        // Full re-analysis asks first; Cancel sends nothing.
        let full = app.buttons["Full re-analysis"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 20))
        // The page enables it again after its job poll sees the re-analysis end (up to a few seconds later).
        XCTAssertTrue(driver.iPadWaitEnabled(full, timeout: 30), "Full re-analysis did not become enabled")
        full.tap()
        driver.expectText("Send the film to the GPU again?")
        driver.expectText("A full re-analysis takes about as long as the first run and costs another GPU run.")
        driver.snapshot("full question L")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        driver.iPadWait(2)
        let jobsAfterCancel = try await api.iPadJobs(gameID: id).count
        XCTAssertEqual(jobsAfterCancel, jobsAfterRerun, "Cancel started a job")

        full.tap()
        app.alerts.buttons["Send to GPU"].firstMatch.tap()
        driver.expectText("Full re-analysis started")
        driver.expectText("Film analysis in progress")
        driver.snapshot("full started L")
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 30))
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testTeamBannerConfirmsTheTeams() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Banner Hawks", film: film, otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Banner Hawks vs Test Rivals")
        driver.expectText("Which team is Test Banner Hawks?")
        driver.expectText("The analysis split the players by jersey colour.")
        let choices = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' jerseys' AND label != 'Roster & jerseys'"))
            .allElementsBoundByIndex
        XCTAssertEqual(choices.count, 2, "expected two jersey colours")
        driver.snapshot("team banner L")
        choices.first?.tap()
        // Either the teams were right ("Thanks - teams confirmed.") or the stats are rebuilt.
        let thanks = driver.iPadAny("Thanks - teams confirmed.")
        let rerun = driver.iPadAny("Re-running the analysis…")
        XCTAssertNotNil(driver.waitForAny([thanks, rerun], timeout: 20), "no toast after choosing a team")
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        XCTAssertTrue(driver.iPadWaitGone(app.staticTexts["Which team is Test Banner Hawks?"], timeout: 30), "the banner stayed")
        let game = try await api.iPadGame(id)
        XCTAssertFalse(((game["team_id_map"] as? [String: Any]) ?? [:]).isEmpty, "team_id_map was not saved")
        driver.iPadRotate(.portrait)
    }

    /// With the sidebar shown the page stacks the film, the event timeline and the tabs.
    @MainActor
    func testStackedLayoutKeepsTheTimelineAboveTheTabs() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let film = try iPadLongFilm.url()
        let id = try await api.iPadAnalysedGame(scoutedTeam: "Test Stack Bulls", film: film, otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Stack Bulls vs Test Rivals")
        let tabs = app.scrollViews["Analysis sections"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20))
        let timeline = app.otherElements["Event timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        driver.iPadScrollPage(by: 520)
        driver.snapshot("stacked timeline and tabs L")
        iPadKnownBug("bug: in the stacked layout the event timeline card is taller than its slot and runs under the tab bar") {
            XCTAssertLessThanOrEqual(timeline.frame.maxY, tabs.frame.minY + 1, "the timeline overlaps the tabs")
        }
        driver.iPadRotate(.portrait)
        driver.iPadWait(1)
        driver.snapshot("stacked portrait")
    }
}
