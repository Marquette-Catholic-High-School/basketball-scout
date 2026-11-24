import XCTest

/// New game and film on iPad (03 §7.2, 04 §6.1): the required team, the film step, Photos, a video link,
/// the replace-film warning, and pause / resume / cancel of a large upload.
///
/// Simulator set-up these tests need (done once from the Mac; the tests skip when it is missing):
/// - Photos: two short test films (`xcrun simctl addmedia <udid> film.mp4`); the right-most one is uploaded.
/// - Files, On My iPad: "Test Big Film.mp4" (a film of about 2 GB, so an upload can be paused before it ends).
final class iPadNewGameUITests: XCTestCase {
    @MainActor
    func testTeamNameIsRequired() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let before = try await driver.api.iPadGames().count
        driver.iPadLaunch(self)
        driver.tapButton("New game")
        XCTAssertTrue(app.navigationBars["New game"].waitForExistence(timeout: 10))
        driver.expectText("1. Game details")
        driver.expectText("Enter the game details, then add the film.")
        driver.tapButton("Continue to film upload")
        driver.snapshot("team needed L")
        // The message is the form's last row: with the on-screen keyboard up it is out of sight.
        iPadKnownBug("bug: with the keyboard up the Team name needed message is below the visible part of the form") {
            XCTAssertTrue(app.staticTexts["Team name needed"].waitForExistence(timeout: 3), "the message is not on screen")
        }
        app.swipeUp()
        driver.expectText("Team name needed")
        driver.expectText("Enter the name of the team you are scouting.")
        driver.snapshot("team needed scrolled L")
        driver.tapButton("Cancel")
        XCTAssertTrue(driver.iPadWaitGone(app.navigationBars["New game"], timeout: 10), "the sheet did not close")
        let after = try await driver.api.iPadGames().count
        XCTAssertEqual(after, before, "a game was created without a team name")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testNewGameWithFilmFromPhotosOpensTheGame() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let team = "Test Photo Lions"
        addTeardownBlock { await api.iPadDeleteGames(scoutedTeam: team) }
        driver.iPadLaunch(self)
        driver.tapButton("New game")
        let teamField = driver.iPadField(placeholder: "Required")
        XCTAssertTrue(teamField.waitForExistence(timeout: 10))
        teamField.tap()
        teamField.typeText(team)
        let other = driver.iPadField(placeholder: "Their opponent in this film")
        other.tap()
        other.typeText("Test Rivals")
        driver.tapButton("Continue to film upload")

        // Step 2 in the same sheet.
        driver.expectText("2. Game film")
        driver.expectText("Game: \(team) vs Test Rivals")
        driver.expectText("Drag and drop the game film here")
        driver.expectText("MP4, MOV or M4V. A wide, full-court angle works best.")
        XCTAssertTrue(app.buttons["Close"].exists, "no Close in step 2")
        driver.snapshot("film step L")

        driver.tapButton("Choose from Photos")
        let items = driver.iPadPhotosItems()
        guard let film = items.last else {
            throw XCTSkip("No video in the simulator's Photos library (add one with simctl addmedia).")
        }
        film.tap()
        // The film is copied from Photos, uploaded, and the analysis starts; the sheet closes and the game opens.
        XCTAssertTrue(driver.iPadWaitGone(app.buttons["Choose from Photos"], timeout: 60), "the upload did not finish")
        XCTAssertTrue(app.staticTexts["\(team) vs Test Rivals"].waitForExistence(timeout: 30), "the new game did not open")
        driver.snapshot("game opened L")
        let ids = try await api.iPadGames().filter { ($0["scouted_team"] as? String) == team }.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, 1, "expected exactly one new game")
        if let id = ids.first {
            try await api.waitForGame(id, status: ["ready"], timeout: 120)
            XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 30), "the results did not appear")
        }
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testVideoLinkIsCheckedThenSaved() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Link Seals", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Link Seals vs Test Rivals")
        driver.tapButton("Add film")
        driver.expectText("Use a video link")
        let link = driver.iPadField(placeholder: "Paste a direct link to an .mp4 file")
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        link.typeText("notalink")
        driver.tapButton("Use this link")
        driver.expectText("Check the link")
        driver.expectText("Enter the full link, including the http or https part at the start.")
        driver.snapshot("bad link L")

        // The mock server does not download the link; any direct http link is accepted.
        driver.replaceText(in: link, with: "http://127.0.0.1:8794/film.mp4")
        driver.tapButton("Use this link")
        try await api.waitForGame(id, status: ["ready"], timeout: 120)
        driver.expectText("Film not available", timeout: 30)
        driver.expectText("It was analyzed from a video link and isn't stored on this server, so it can't be played here.")
        XCTAssertTrue(app.buttons["Upload the film"].exists)
        XCTAssertTrue(app.buttons["Box score"].waitForExistence(timeout: 20))
        driver.snapshot("link game ready L")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testReplaceFilmWarnsWhatItReplaces() async throws {
        let driver = try ScoutAppDriver(self)
        let api = driver.api
        let film = try ScoutUITestFilm.url()
        let id = try await api.iPadUploadedGame(scoutedTeam: "Test Replace Cubs", film: film)
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Replace Cubs vs Test Opponent")
        driver.expectText("This film hasn't been analyzed yet.")
        driver.tapButton("Replace film")
        driver.expectText("This game already has film")
        driver.expectText("New film replaces uitest-film.mp4 and runs the analysis again.")
        driver.snapshot("replace film L")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testLargeUploadPausesResumesAndCancels() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Big Film Moose", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Big Film Moose vs Test Rivals")
        driver.tapButton("Add film")
        driver.tapButton("Choose a file")
        let bigFilm = app.cells["Test Big Film, mp4"].firstMatch
        let onMyIPad = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        if onMyIPad.waitForExistence(timeout: 10), !onMyIPad.isSelected { onMyIPad.tap() }
        guard bigFilm.waitForExistence(timeout: 10) else {
            throw XCTSkip("Put a film of about 2 GB named \"Test Big Film.mp4\" in the simulator's On My iPad folder.")
        }
        bigFilm.tap()

        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30), "no Pause while uploading")
        pause.tap()
        driver.expectText("Paused")
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))
        driver.expectText("Test Big Film.mp4")
        driver.expectText("Upload paused") // the sidebar row's badge
        driver.snapshot("paused L")

        app.buttons["Resume"].firstMatch.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "the upload did not resume")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))

        driver.tapButton("Cancel upload")
        driver.expectText("Cancel this upload? The part already sent will be discarded.")
        driver.snapshot("cancel question L")
        let confirm = app.alerts.buttons["Cancel upload"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Choose a file"].waitForExistence(timeout: 15), "the choices did not come back")
        let game = try await api.iPadGame(id)
        XCTAssertEqual(game["status"] as? String, "draft", "the cancelled upload left film on the game")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testFileThatIsNotAFilmIsRefused() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await api.createGame(scoutedTeam: "Test Fake Film Toads", otherTeam: "Test Rivals")
        addTeardownBlock { await api.deleteGame(id) }
        driver.iPadLaunch(self)
        driver.iPadOpenGame("Test Fake Film Toads vs Test Rivals")
        driver.tapButton("Add film")
        driver.tapButton("Choose a file")
        let onMyIPad = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        if onMyIPad.waitForExistence(timeout: 10), !onMyIPad.isSelected { onMyIPad.tap() }
        let fake = app.cells["Not A Film, mp4"].firstMatch
        guard fake.waitForExistence(timeout: 10) else {
            throw XCTSkip("Put a 20-byte text file named \"Not A Film.mp4\" in the simulator's On My iPad folder.")
        }
        driver.snapshot("files picker L")
        driver.iPadAttachTreeIfNeeded(self, "files-picker")
        if fake.isEnabled {
            fake.tap()
            // The server refuses it at the end of the upload; the app shows its error and offers another file.
            XCTAssertTrue(app.buttons["Choose another file"].waitForExistence(timeout: 60), "no error after a fake film")
            driver.snapshot("fake film refused L")
        } else {
            // The picker greys it out (it is not a movie by content), so it cannot be chosen at all.
            app.buttons["Cancel"].firstMatch.tap()
        }
        let game = try await api.iPadGame(id)
        XCTAssertEqual(game["has_video"] as? Bool, false)
        driver.iPadRotate(.portrait)
    }
}

extension ScoutAppDriver {
    /// Attaches the accessibility tree (used where a test meets system UI whose labels can change).
    func iPadAttachTreeIfNeeded(_ testCase: XCTestCase, _ name: String) {
        testCase.iPadAttachTree(app, name)
    }
}
