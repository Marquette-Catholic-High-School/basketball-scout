#if os(iOS)
import XCTest

/// New game and film on iPhone (03 §7.2, 04 §6.1): the form, the film step, a film from Photos with the
/// copy and upload panels, pause / resume / cancel, a video link, and the Replace film warning.
///
/// The Photos tests need two films in the simulator's Photos library (they are skipped otherwise): a short
/// one (about 20 s, the picker reads it as "Video, twenty seconds") and a large one (about 1 GB, 1 min 40 s)
/// so the upload panel can be seen while it runs. The tester adds them with `xcrun simctl addmedia`.
final class iPhoneNewGameTests: XCTestCase {
    /// Picks the video whose VoiceOver label begins with `prefix` in the system Photos picker and waits for
    /// the picker to close (the upload panel behind it already has its buttons, but a tap there while the
    /// picker is still on screen is lost); skips the test when the library has no such film.
    @MainActor
    private func pickVideo(_ kit: iPhoneKit, _ prefix: String, waitForClose: Bool = true) throws {
        let video = kit.app.images.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        guard video.waitForExistence(timeout: 15) else {
            kit.shot("no-film-in-photos")
            throw XCTSkip("The simulator's Photos library has no \"\(prefix)…\" film (add one with xcrun simctl addmedia).")
        }
        kit.pause(1)
        video.tap()
        guard waitForClose else { return }
        XCTAssertTrue(kit.waitGone(video, 15), "the Photos picker did not close")
        kit.pause(0.5)
    }

    /// Pauses the upload as early as it can: the local server takes the 1 GB film at up to 1 GB/s, so the
    /// upload can finish within a second. Taps Pause until "Resume" shows (a tap while the Photos picker is
    /// still closing is lost); false when the upload finished first.
    @MainActor
    private func pauseEarly(_ kit: iPhoneKit) -> Bool {
        let pause = kit.app.buttons["Pause"].firstMatch
        let resume = kit.app.buttons["Resume"].firstMatch
        guard pause.waitForExistence(timeout: 90) else {
            XCTFail("the upload did not start")
            return false
        }
        for _ in 0..<8 {
            if resume.exists { return true }
            if pause.exists { pause.tap() }
            if resume.waitForExistence(timeout: 1) { return true }
            if !pause.exists && !resume.exists { return false }
        }
        return resume.exists
    }

    /// The team is required: "Continue" with a blank team keeps the form, marks the field and explains.
    /// The explanation is the web's error box, but on iPhone it lands at the end of the long form, under the
    /// keyboard, where the coach does not see it.
    @MainActor
    func testTeamIsRequired() async throws {
        let kit = try iPhoneKit(self, tag: "team-required")
        let app = kit.app
        kit.launchSignedIn()
        kit.tap(app.buttons["New game"].firstMatch)
        XCTAssertTrue(kit.wait(app.navigationBars["New game"], 5))
        XCTAssertTrue(kit.any("1. Game details").exists)
        XCTAssertTrue(kit.any("Enter the game details, then add the film.").exists)
        kit.shot("form")
        let before = try await kit.api.iPhoneGames().count
        kit.tapButton("Continue to film upload")
        kit.pause(1)
        XCTAssertTrue(app.navigationBars["New game"].exists, "the form went on without a team")
        kit.shot("team-needed")
        let message = kit.any("Team name needed")
        kit.expectBug("bug: on iPhone the Team name needed box is at the end of the form, under the keyboard (off screen)") {
            XCTAssertTrue(message.exists && kit.isVisible(message), "the Team name needed message is off screen")
        }
        // It is the form's last row: there once scrolled to (with the keyboard up: dragging it away would pull
        // the empty form's sheet down and close it).
        kit.scrollIntoView(message, maxSwipes: 8)
        XCTAssertTrue(message.exists, "no Team name needed message")
        XCTAssertTrue(kit.any("Enter the name of the team you are scouting.").exists)
        kit.shot("team-needed-scrolled")
        let after = try await kit.api.iPhoneGames().count
        XCTAssertEqual(before, after, "a game was created without a team")
        kit.tapButton("Cancel")
        XCTAssertTrue(kit.wait(kit.driver.gamesList, 5))
    }

    /// The full new-game flow: the form (opponent, level from the menu, date, light jerseys), "Continue",
    /// the film step, a film from Photos (copy, upload), then the game opens and its analysis runs to
    /// "Ready". The game is created with what was typed.
    @MainActor
    func testNewGameWithFilmFromPhotos() async throws {
        let kit = try iPhoneKit(self, tag: "new-game")
        let app = kit.app
        let api = kit.api
        let team = "iPT New \(Int.random(in: 100...999))"
        addTeardownBlock { await api.iPhoneDeleteGames(prefix: team) }
        kit.launchSignedIn()
        kit.tap(app.buttons["New game"].firstMatch)
        XCTAssertTrue(kit.wait(app.navigationBars["New game"], 5))
        kit.type(team, into: kit.field(placeholder: "Required"))
        kit.type("Test Opponent", into: kit.field(placeholder: "Their opponent in this film"))
        kit.tap(app.buttons["Level suggestions"].firstMatch)
        kit.tap(app.buttons["JV"].firstMatch, timeout: 5)
        XCTAssertEqual(kit.field(placeholder: "Varsity, JV…").value as? String, "JV", "the level menu did not fill the field")
        // The Game date switch: a tap on its words does nothing (as in Settings); tap the switch itself.
        let dateSwitch = app.switches["Game date"].firstMatch
        XCTAssertTrue(kit.wait(dateSwitch, 5), "no Game date switch")
        let knob = dateSwitch.switches.firstMatch
        let target = knob.waitForExistence(timeout: 2) ? knob : dateSwitch
        kit.tap(target)
        // A tap that lands while the form is still settling after a scroll only stops the scroll: once more.
        if !kit.wait(dateSwitch, until: "value == '1'", 3) {
            kit.pause(0.5)
            target.tap()
        }
        XCTAssertTrue(kit.wait(dateSwitch, until: "value == '1'", 5), "the Game date switch did not turn on")
        XCTAssertTrue(kit.wait(app.datePickers.firstMatch, 5), "no date picker under Game date")
        kit.tap(app.buttons["Light"].firstMatch)
        kit.shot("form-filled")
        kit.tapButton("Continue to film upload")

        // Step 2 replaces the form in the same sheet.
        XCTAssertTrue(kit.wait(kit.any("2. Game film"), 10), "the film step did not appear")
        XCTAssertTrue(kit.wait(kit.any("Game: \(team) vs Test Opponent"), 10), "no Game: line on the film step")
        XCTAssertTrue(app.buttons["Close"].exists, "no Close on the film step")
        kit.shot("film-step")
        let game = try await api.iPhoneGames().first { ($0["scouted_team"] as? String) == team }
        XCTAssertNotNil(game, "the game was not created")
        XCTAssertEqual(game?["level"] as? String, "JV")
        XCTAssertEqual(game?["scouted_color"] as? String, "light")
        XCTAssertEqual(game?["other_team"] as? String, "Test Opponent")
        XCTAssertNotNil(game?["game_date"] as? String, "the game date was not sent")

        kit.tapButton("Choose from Photos")
        try pickVideo(kit, "Video, twenty seconds")
        // The film is copied from Photos, uploaded, and the game page opens with the analysis.
        let opened = kit.app.buttons["Game actions"].firstMatch
        XCTAssertTrue(kit.wait(opened, 60), "the game did not open after the upload")
        kit.shot("game-opened")
        XCTAssertTrue(kit.wait(kit.any("Box score"), 90), "the analysis did not finish")
        XCTAssertTrue(kit.wait(kit.exact("Ready"), 30), "no Ready badge after the analysis")
        kit.shot("analysed")
    }

    /// A large film: the copy from Photos, then the upload panel with percent, size, speed and time left;
    /// Pause, Resume, the cancel question ("Keep uploading"), and the finished upload opening the game page.
    @MainActor
    func testUploadPanelPauseResumeAndFinish() async throws {
        let kit = try iPhoneKit(self, tag: "upload")
        let app = kit.app
        let api = kit.api
        let team = "iPT Upload \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.any("No film yet"), 10))
        kit.tapButton("Add film")
        XCTAssertTrue(kit.wait(kit.any("Game film"), 10), "Add film did not open the film screen")
        kit.tapButton("Choose from Photos")
        try pickVideo(kit, "Video, one minute", waitForClose: false)
        let pause = app.buttons["Pause"].firstMatch
        let resume = app.buttons["Resume"].firstMatch
        let page = app.buttons["Game actions"].firstMatch
        if pauseEarly(kit) {
            XCTAssertTrue(kit.wait(kit.exact("Paused"), 5), "no Paused status")
            XCTAssertTrue(kit.any("MB uploaded").exists, "no amount uploaded while paused")
            kit.shot("paused")
            // The cancel question, answered "Keep uploading": still paused.
            kit.tapButton("Cancel upload")
            let question = app.alerts.firstMatch
            XCTAssertTrue(question.waitForExistence(timeout: 5), "Cancel upload does not ask first")
            XCTAssertTrue(question.staticTexts["Cancel this upload? The part already sent will be discarded."].exists)
            kit.shot("cancel-question")
            kit.tap(kit.alertButton("Keep uploading"))
            XCTAssertTrue(kit.wait(resume, 5), "Keep uploading did not keep the paused upload")
            resume.tap()
            // Resumed: Pause again, or (the rest goes up in a moment here) the finished upload's game page.
            XCTAssertNotNil(kit.driver.waitForAny([pause, page, kit.any("Finishing upload")], timeout: 15), "Resume did not resume")
            XCTAssertFalse(resume.exists, "still paused after Resume")
        } else {
            kit.shot("finished-before-pause")
        }
        // The finished upload opens the game page, which follows the analysis.
        XCTAssertTrue(kit.wait(app.buttons["Game actions"].firstMatch, 120), "the game page did not come back after the upload")
        XCTAssertTrue(kit.wait(kit.any("Box score"), 120), "the analysis of the uploaded film did not finish")
        kit.shot("analysed")
        let game = try await api.iPhoneGame(gameID)
        XCTAssertGreaterThan(game["video_size"] as? Int ?? 0, 500_000_000, "the server did not get the whole film")
    }

    /// Cancel while paused: the question, then the film choices come back and the game still has no film.
    @MainActor
    func testCancelPausedUpload() async throws {
        let kit = try iPhoneKit(self, tag: "cancel-upload")
        let app = kit.app
        let api = kit.api
        let team = "iPT Cancel Upload \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.tapButton("Add film")
        kit.tapButton("Choose from Photos")
        try pickVideo(kit, "Video, one minute", waitForClose: false)
        guard pauseEarly(kit) else {
            kit.shot("finished-before-pause")
            throw XCTSkip("The upload finished before Pause took effect (the local server takes the 1 GB film at up to 1 GB/s); nothing left to cancel.")
        }
        kit.tapButton("Cancel upload")
        XCTAssertTrue(kit.wait(app.alerts.firstMatch, 5), "Cancel upload does not ask first")
        kit.tap(kit.alertButton("Cancel upload"))
        XCTAssertTrue(kit.wait(kit.button("Choose from Photos"), 10), "the film choices did not come back")
        kit.shot("cancelled")
        let game = try await api.iPhoneGame(gameID)
        XCTAssertEqual(game["has_video"] as? Bool, false, "the cancelled upload left film on the server")
        XCTAssertEqual(game["status"] as? String, "draft")
    }

    /// The video link form: the web's check of the link, then a direct link saves the film and starts the
    /// analysis; the analysed link game says its film is not stored on the server (03 §7.7).
    @MainActor
    func testVideoLink() async throws {
        let kit = try iPhoneKit(self, tag: "link")
        let app = kit.app
        let api = kit.api
        let team = "iPT Link \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.tapButton("Add film")
        XCTAssertTrue(kit.wait(kit.any("Use a video link"), 10))
        let link = kit.field(placeholder: "Paste a direct link to an .mp4 file")
        // The keyboard covers "Use this link" on iPhone; its Go key submits the link.
        kit.type("not a link", into: link)
        link.typeText("\n")
        XCTAssertTrue(kit.wait(kit.any("Check the link"), 5), "no message for a malformed link")
        XCTAssertTrue(kit.any("Enter the full link, including the http or https part at the start.").exists)
        kit.shot("bad-link")
        // The mock processor never downloads the link; a local test server serves the film for real runs.
        kit.type("http://127.0.0.1:8799/iphone-court-small.mp4", into: link)
        link.typeText("\n")
        XCTAssertTrue(kit.wait(app.buttons["Game actions"].firstMatch, 20), "saving the link did not return to the game")
        XCTAssertTrue(kit.wait(kit.any("Film not available"), 90), "the analysed link game does not say its film is not stored")
        XCTAssertTrue(kit.any("It was analyzed from a video link and isn't stored on this server").exists)
        XCTAssertTrue(kit.button("Upload the film").exists)
        kit.shot("link-analysed")
        let game = try await api.iPhoneGame(gameID)
        XCTAssertEqual(game["video_url"] as? String, "http://127.0.0.1:8799/iphone-court-small.mp4")
    }

    /// Replace film on a game with film: the web's warning names the current film.
    @MainActor
    func testReplaceFilmWarns() async throws {
        let kit = try iPhoneKit(self, tag: "replace")
        let api = kit.api
        let team = "iPT Replace \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.gameAction("Replace film")
        XCTAssertTrue(kit.wait(kit.app.navigationBars["Replace film"], 10), "no Replace film screen")
        XCTAssertTrue(kit.any("This game already has film").exists)
        let film = try ScoutUITestFilm.url().lastPathComponent
        XCTAssertTrue(kit.any("New film replaces \(film) and runs the analysis again.").exists, "the warning does not name the film")
        kit.shot("replace-warning")
        kit.back()
        XCTAssertTrue(kit.wait(kit.app.buttons["Game actions"].firstMatch, 5))
    }
}
#endif
