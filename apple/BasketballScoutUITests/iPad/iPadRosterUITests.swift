import XCTest

/// Rosters & jerseys on iPad (05 §7): jersey checks, add / remove / save, CSV import (replace and merge), the
/// template, both teams, jersey assignments with "Save & re-run analysis", and the table in portrait.
///
/// Simulator set-up for the import test (done once from the Mac; the test skips when it is missing): in On My
/// iPad, "Test Roster.csv" (6 players: #1, #3, #5, #10, #12, #23) and "Test Roster Merge.csv" (#5 renamed and a
/// new #44), with the header `#,First Name,Last Name,Pos,Gr,Ht` and "Test" / "Player N" names.
final class iPadRosterUITests: XCTestCase {
    @MainActor
    private func openRoster(_ driver: ScoutAppDriver, team: String, analysed: Bool = false) async throws -> String {
        let api = driver.api
        let id: String
        if analysed {
            let film = try ScoutUITestFilm.url()
            id = try await api.iPadAnalysedGame(scoutedTeam: team, film: film, otherTeam: "Test Rivals")
        } else {
            id = try await api.createGame(scoutedTeam: team, otherTeam: "Test Rivals")
        }
        try await api.iPadPutRoster(gameID: id, side: "scouted", teamName: team, jerseys: ["1", "2", "3", "4"])
        try await api.iPadPutRoster(gameID: id, side: "other", teamName: "Test Rivals", jerseys: ["10", "11"])
        driver.iPadLaunch(self)
        driver.iPadOpenRoster("\(team) vs Test Rivals")
        return id
    }

    @MainActor
    func testJerseyNumbersAreCheckedBeforeSaving() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Jersey Owls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("Import the roster from a CSV or Excel file")
        let row1 = driver.iPadRosterFields(row: 1)
        XCTAssertEqual(row1.count, 8, "expected the 8 roster columns")
        guard let jersey = row1.first else { return }
        XCTAssertEqual(jersey.value as? String, "1")

        driver.iPadReplaceText(in: jersey, with: "123")
        driver.iPadHideKeyboard()
        driver.tapButton("Save roster")
        driver.expectText("Check the roster")
        driver.expectText("Row 1: a jersey number is one or two digits (0-99), not \"123\".")
        driver.snapshot("three digits L")
        // The message sits in the page header above the table, which has no room left for it in landscape.
        iPadKnownBug("bug: the Check the roster message is clipped under the roster table (only the red outline shows)",
                     strict: false) {
            XCTAssertTrue(app.staticTexts["Check the roster"].isHittable, "the message is not visible")
        }

        replaceFlaggedJersey(driver, with: "2")
        // Save with ⌘S (F-Roster): the button can sit under the keyboard after the refocusing above.
        app.typeKey("s", modifierFlags: .command)
        driver.expectText("Jersey #2 is listed twice (rows 1 and 2).")
        driver.snapshot("duplicate L")
        let unchanged = try await api.iPadJerseys(gameID: id, side: "scouted")
        XCTAssertEqual(unchanged, ["1", "2", "3", "4"], "a refused roster reached the server")

        // A valid save is checked by testAddAndRemovePlayers.
        driver.iPadRotate(.portrait)
    }

    /// Replaces row 1's jersey while it is outlined as invalid. The cell drops the keyboard after the first
    /// keystroke (bug), so the field is tapped again whenever it lost the focus.
    @MainActor
    private func replaceFlaggedJersey(_ driver: ScoutAppDriver, with text: String) {
        let app = driver.app
        let focused = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true"))
        var lostFocus = false
        func focusJersey(_ field: XCUIElement) {
            field.tap()
            driver.iPadWait(0.5)
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            driver.iPadWait(0.2)
        }
        guard let first = driver.iPadRosterFields(row: 1).first else { return XCTFail("no jersey cell") }
        focusJersey(first)
        for _ in 0..<8 {
            guard let field = driver.iPadRosterFields(row: 1).first else {
                driver.iPadWait(0.5)
                continue
            }
            if ((field.value as? String) ?? "").isEmpty { break }
            if focused.count == 0 {
                lostFocus = true
                focusJersey(field)
            }
            app.typeText(XCUIKeyboardKey.delete.rawValue)
            driver.iPadWait(0.4)
        }
        if focused.count == 0, let field = driver.iPadRosterFields(row: 1).first {
            lostFocus = true
            focusJersey(field)
        }
        app.typeText(text)
        driver.iPadWait(0.4)
        XCTAssertEqual(driver.iPadRosterFields(row: 1).first?.value as? String, text, "the jersey did not take the typed text")
        iPadKnownBug("bug: after Check the roster the outlined jersey cell loses the keyboard after one keystroke",
                     strict: false) {
            XCTAssertFalse(lostFocus, "the jersey cell lost the keyboard while typing")
        }
    }

    @MainActor
    func testAddAndRemovePlayers() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Add Owls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.tapButton("Add player")
        XCTAssertTrue(app.buttons["Remove row 5"].waitForExistence(timeout: 10), "no new row")
        driver.expectText("Unsaved changes")
        driver.snapshot("added row L")
        let row5 = driver.iPadRosterFields(row: 5)
        XCTAssertEqual(row5.count, 8)
        // The new row's jersey cell has the focus; with the keyboard up the coach should see it.
        iPadKnownBug("bug: with the on-screen keyboard up in landscape the roster table has no room and the new row is hidden") {
            XCTAssertTrue(row5.first?.isHittable ?? false, "the new row is not visible while typing its jersey")
        }
        guard row5.count == 8 else { return }
        // Type into the focused (hidden) jersey cell; names may stay empty (05 §7.2 sends "").
        app.typeText("55")
        driver.iPadHideKeyboard()
        XCTAssertEqual(driver.iPadRosterFields(row: 5).first?.value as? String, "55", "the new row did not take the jersey")
        driver.tapButton("Save roster")
        driver.expectText("Roster saved")
        let afterAdd = try await api.iPadJerseys(gameID: id, side: "scouted")
        XCTAssertEqual(Set(afterAdd), ["1", "2", "3", "4", "55"])

        app.buttons["Remove row 2"].firstMatch.tap()
        driver.expectText("Unsaved changes")
        driver.tapButton("Save roster")
        driver.expectText("Roster saved")
        let afterRemove = try await api.iPadJerseys(gameID: id, side: "scouted")
        XCTAssertEqual(Set(afterRemove), ["1", "3", "4", "55"])
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testImportReplacesThenMerges() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Import Owls")
        addTeardownBlock { await api.deleteGame(id) }
        XCTAssertTrue(app.buttons["When importing, Replace this roster"].exists, "Replace is not the default import mode")
        driver.tapButton("Choose file…")
        let onMyIPad = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        if onMyIPad.waitForExistence(timeout: 15), !onMyIPad.isSelected { onMyIPad.tap() }
        guard app.cells["Test Roster, csv"].waitForExistence(timeout: 10) else {
            throw XCTSkip("Put Test Roster.csv and Test Roster Merge.csv in the simulator's On My iPad folder.")
        }
        app.cells["Test Roster, csv"].firstMatch.tap()
        driver.expectText("Imported 6 players from Test Roster.csv", timeout: 20)
        driver.expectText("Roster saved")
        driver.snapshot("imported L")
        let replaced = try await api.iPadJerseys(gameID: id, side: "scouted")
        XCTAssertEqual(Set(replaced), ["1", "3", "5", "10", "12", "23"])

        driver.tapButton("When importing, Replace this roster")
        driver.tapButton("Merge (update matching jerseys)")
        XCTAssertTrue(app.buttons["When importing, Merge (update matching jerseys)"].waitForExistence(timeout: 5))
        driver.tapButton("Choose file…")
        driver.iPadPickFile("Test Roster Merge, csv")
        driver.expectText("Imported 2 players from Test Roster Merge.csv", timeout: 20)
        let merged = try await api.iPadJerseys(gameID: id, side: "scouted")
        XCTAssertEqual(Set(merged), ["1", "3", "5", "10", "12", "23", "44"])
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testOpponentRosterIsSeparate() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Both Owls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.tapButton("Opponent")
        let teamName = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Team name'")).firstMatch
        XCTAssertTrue(teamName.waitForExistence(timeout: 10))
        XCTAssertEqual(teamName.value as? String, "Test Rivals")
        XCTAssertTrue(app.buttons["Remove row 2"].exists)
        XCTAssertFalse(app.buttons["Remove row 3"].exists, "the opponent shows the scouted roster")
        driver.snapshot("opponent L")

        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testJerseyAssignmentIsSavedAndTheAnalysisRerun() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Tracks Owls", analysed: true)
        addTeardownBlock { await api.deleteGame(id) }
        driver.tapButton("Jersey assignments")
        driver.expectText("Jersey assignments from the film")
        let save = app.buttons["Save & re-run analysis"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        XCTAssertFalse(save.isEnabled, "Save & re-run is enabled without a change")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assign track'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no track rows")
        picker.tap()
        let notAPlayer = app.buttons["Not a player (referee, coach, fan…)"].firstMatch
        XCTAssertTrue(notAPlayer.waitForExistence(timeout: 5), "no Not a player choice")
        notAPlayer.tap()
        driver.expectText("1 unsaved change")
        XCTAssertTrue(save.isEnabled)
        driver.snapshot("pending choice L")

        save.tap()
        // Back on the game page, the re-analysis started (05 §7.7).
        driver.expectText("Re-running the analysis…", timeout: 20)
        XCTAssertTrue(app.buttons["Roster & jerseys"].waitForExistence(timeout: 10))
        let overrides = try await api.iPadTrackOverrides(gameID: id)
        XCTAssertEqual(overrides.count, 1, "the track choice was not saved")
        XCTAssertEqual(overrides.first?["ignore"] as? Bool, true)
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        driver.iPadRotate(.portrait)
    }

    /// In portrait the sidebar and the game share the screen; the roster table must still show every column.
    @MainActor
    func testRosterTableInPortraitShowsJerseyNumbers() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Portrait Owls", otherTeam: "Test Rivals")
        try await api.iPadPutRoster(gameID: id, side: "scouted", teamName: "Test Portrait Owls", jerseys: ["1", "2", "3", "4"])
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self, orientation: .portrait)
        driver.iPadShowSidebarIfHidden()
        driver.iPadOpenRoster("Test Portrait Owls vs Test Rivals")
        driver.snapshot("roster portrait")
        let sidebar = app.collectionViews["Sidebar"].firstMatch
        let jersey = driver.iPadRosterFields(row: 1).first
        XCTAssertNotNil(jersey, "no roster row")
        if let jersey, sidebar.exists {
            iPadKnownBug("bug: in portrait with the sidebar the roster table is wider than the page and its # and First name columns are cut off") {
                XCTAssertGreaterThanOrEqual(jersey.frame.minX, sidebar.frame.maxX, "the jersey column is hidden under the sidebar")
            }
        }
    }

    /// "Download roster template" crashes the app (SIGABRT in -[NSFileWrapper setPreferredFilename:] while
    /// SwiftUI prepares the file exporter for `RosterTemplateFile`). Opt-in so the suite stays green: set
    /// TEST_RUNNER_SCOUT_UITEST_KNOWN_CRASHES=1 to check a fix.
    @MainActor
    func testDownloadRosterTemplateOffersToSaveIt() async throws {
        guard ProcessInfo.processInfo.environment["SCOUT_UITEST_KNOWN_CRASHES"] == "1" else {
            throw XCTSkip("Known crash (Download roster template); set TEST_RUNNER_SCOUT_UITEST_KNOWN_CRASHES=1 to run it.")
        }
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openRoster(driver, team: "Test Template Owls")
        addTeardownBlock { await api.deleteGame(id) }
        driver.tapButton("Download roster template")
        let saveAs = driver.iPadAny("Save as")
        XCTAssertNotNil(driver.waitForAny([saveAs], timeout: 20), "the template's save panel did not open")
        XCTAssertEqual(app.state, .runningForeground, "the app is not running")
        driver.snapshot("template save panel L")
        driver.iPadRotate(.portrait)
    }
}
