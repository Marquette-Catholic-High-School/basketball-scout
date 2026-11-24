#if os(iOS)
import XCTest

/// Rosters & jerseys on iPhone (05 §7): both rosters, a player's form, the jersey rules (one or two digits,
/// no duplicates), adding and saving (toast and the "Roster saved" banner with Re-run analysis), importing a
/// CSV (replace, merge), the template, jersey assignments with "Save & re-run analysis", and the question
/// when leaving with unsaved changes.
final class iPhoneRosterTests: XCTestCase {
    /// Opens the roster page of a new analysed game (both rosters "Test Player N").
    @MainActor
    private func openRoster(_ kit: iPhoneKit, team: String) async throws -> String {
        let gameID = try await kit.api.iPhoneAnalysedGame(team: team)
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.gameAction("Roster & jerseys")
        XCTAssertTrue(kit.wait(kit.app.navigationBars["Rosters & jerseys"], 10), "the roster page did not open")
        XCTAssertTrue(kit.wait(kit.buttonStarting("#0, Test Player 1"), 15), "the roster did not load")
        return gameID
    }

    /// The player row of `jersey` ("#5, Test Player 4, …").
    @MainActor
    private func player(_ kit: iPhoneKit, _ jersey: String) -> XCUIElement {
        kit.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "#\(jersey), ")).firstMatch
    }

    /// Opens `jersey`'s form, types `newJersey` into its number and goes back.
    @MainActor
    private func setJersey(_ kit: iPhoneKit, of jersey: String, to newJersey: String) {
        let row = player(kit, jersey)
        kit.scrollIntoView(row)
        kit.tap(row)
        let field = kit.field(placeholder: "Jersey")
        XCTAssertTrue(kit.wait(field, 5), "no player form")
        kit.type(newJersey, into: field)
        kit.back()
    }

    /// Both rosters and the jersey assignments; a player's form; the jersey rules on Save (the web's
    /// messages, 05 §7.2): three digits, then a duplicate; fixing it saves (toast, "Roster saved" banner).
    @MainActor
    func testJerseyRulesAndSave() async throws {
        let kit = try iPhoneKit(self, tag: "roster-rules")
        let app = kit.app
        let api = kit.api
        let team = "iPT Roster Rules \(Int.random(in: 100...999))"
        let gameID = try await openRoster(kit, team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        XCTAssertTrue(app.buttons["Scouted team"].isSelected)
        kit.shot("scouted")
        kit.tap(app.buttons["Opponent"].firstMatch)
        XCTAssertTrue(kit.wait(kit.field(placeholder: "Team name"), 5))
        XCTAssertEqual(kit.field(placeholder: "Team name").value as? String, "Test Opponent")
        kit.shot("opponent")
        kit.tap(app.buttons["Jersey assignments"].firstMatch)
        XCTAssertTrue(kit.wait(kit.buttonStarting("Track "), 10), "no tracks")
        kit.shot("tracks")
        kit.tap(app.buttons["Scouted team"].firstMatch)

        // A player's form: every field.
        let row = player(kit, "5")
        kit.scrollIntoView(row)
        kit.tap(row)
        for field in ["Jersey", "First name", "Last name", "FastScout name", "Position", "Grade", "Height", "Notes"] {
            XCTAssertTrue(kit.field(placeholder: field).exists, "the player form lacks \(field)")
        }
        XCTAssertTrue(kit.button("Remove player").exists)
        kit.shot("player-form")
        // Letters are dropped as typed (R41, F-Roster); three digits are kept (maxlength 3) and refused on Save.
        let jersey = kit.field(placeholder: "Jersey")
        kit.clear(jersey)
        jersey.typeText("a1b")
        kit.shot("jersey-a1b")
        // Seen in most runs, not all (it depends on the typing speed): not strict.
        kit.expectBug("bug: the jersey field shows letters typed into it although the roster keeps only the digits", strict: false) {
            XCTAssertEqual(jersey.value as? String, "1", "the jersey field shows letters")
        }
        kit.type("123", into: jersey)
        kit.back()
        XCTAssertTrue(kit.wait(kit.any("Unsaved changes"), 5), "no Unsaved changes note")
        kit.tapButton("Save roster")
        XCTAssertTrue(kit.wait(kit.any("a jersey number is one or two digits (0-99), not \"123\"."), 5), "no message for three digits")
        kit.shot("three-digits")
        // A duplicate.
        setJersey(kit, of: "123", to: "14")
        kit.tapButton("Save roster")
        XCTAssertTrue(kit.wait(kit.any("Jersey #14 is listed twice"), 5), "no message for a duplicate jersey")
        kit.shot("duplicate")
        let saved = try await api.iPhoneRoster(gameID, side: "scouted")
        XCTAssertFalse(((saved["players"] as? [[String: Any]]) ?? []).contains { ($0["jersey"] as? String) == "123" }, "an invalid roster was saved")
        // Fixed: saved.
        let duplicates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '#14, '")).allElementsBoundByIndex
        XCTAssertEqual(duplicates.count, 2)
        setJersey(kit, of: "14", to: "77")
        kit.tapButton("Save roster")
        XCTAssertTrue(kit.wait(kit.any("Roster saved"), 10), "no Roster saved toast or banner")
        kit.shot("saved")
        kit.scrollToTop()
        XCTAssertTrue(kit.wait(kit.any("Names and jersey matches update after the analysis runs again"), 5), "no Roster saved banner")
        XCTAssertTrue(kit.buttonStarting("Re-run analysis").exists, "the banner has no Re-run analysis")
        kit.shot("banner")
        let after = try await api.iPhoneRoster(gameID, side: "scouted")
        XCTAssertTrue(((after["players"] as? [[String: Any]]) ?? []).contains { ($0["jersey"] as? String) == "77" }, "the fixed roster was not saved")
    }

    /// "Add player" opens a new player's form with the jersey focused; leaving with unsaved changes asks
    /// first ("Discard unsaved changes?"); "Remove player" removes one; saving keeps both changes.
    @MainActor
    func testAddPlayerAndLeaveQuestion() async throws {
        let kit = try iPhoneKit(self, tag: "roster-add")
        let app = kit.app
        let api = kit.api
        let team = "iPT Roster Add \(Int.random(in: 100...999))"
        let gameID = try await openRoster(kit, team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let add = kit.button("Add player")
        kit.scrollIntoView(add)
        kit.tap(add)
        XCTAssertTrue(kit.wait(app.navigationBars["New player"], 5), "no New player form")
        let jersey = kit.field(placeholder: "Jersey")
        XCTAssertTrue(kit.wait(jersey, until: "hasKeyboardFocus == true", 5), "the jersey is not focused")
        jersey.typeText("88")
        kit.type("Test", into: kit.field(placeholder: "First name"))
        kit.type("Player 99", into: kit.field(placeholder: "Last name"))
        kit.shot("new-player")
        kit.back()
        XCTAssertTrue(kit.wait(player(kit, "88"), 5), "the new player is not listed")
        // Leaving now asks.
        let backToGame = app.buttons["Back to game"].firstMatch
        XCTAssertTrue(kit.wait(backToGame, 5), "no Back to game while changes are unsaved")
        backToGame.tap()
        XCTAssertTrue(kit.wait(app.alerts.firstMatch, 5), "leaving with unsaved changes does not ask")
        XCTAssertTrue(app.alerts.staticTexts["Discard unsaved changes?"].exists)
        kit.shot("leave-question")
        kit.tap(kit.alertButton("Keep Editing"))
        // Remove a player from its form.
        let removed = player(kit, "55")
        kit.scrollIntoView(removed)
        kit.tap(removed)
        kit.tapButton("Remove player")
        XCTAssertTrue(kit.waitGone(player(kit, "55"), 5), "the removed player is still listed")
        kit.tapButton("Save roster")
        XCTAssertTrue(kit.wait(kit.any("Roster saved"), 10))
        let roster = try await api.iPhoneRoster(gameID, side: "scouted")
        let players = (roster["players"] as? [[String: Any]]) ?? []
        let added = players.first { ($0["jersey"] as? String) == "88" }
        XCTAssertEqual(added?["last_name"] as? String, "Player 99")
        XCTAssertFalse(players.contains { ($0["jersey"] as? String) == "55" }, "the removed player was saved")
        XCTAssertEqual(players.count, ScoutUITestAPI.iPhoneTestPlayers.count, "one added and one removed")
        // Saved: the back button is the system one again.
        XCTAssertTrue(kit.waitGone(backToGame, 5), "Back to game stayed after saving")
    }

    /// Import a CSV from Files: Replace (default), then Merge; the summary of each.
    @MainActor
    func testImportCSVReplaceThenMerge() async throws {
        let kit = try iPhoneKit(self, tag: "roster-import")
        let app = kit.app
        let api = kit.api
        let replaceName = "iphone-ut-replace-\(Int.random(in: 100...999)).csv"
        let mergeName = "iphone-ut-merge-\(Int.random(in: 100...999)).csv"
        try iPhoneFiles.put(replaceName, text: "#,First name,Last name,Position\n1,Test,Player 1,G\n2,Test,Player 2,F\n3,Test,Player 3,C\n")
        try iPhoneFiles.put(mergeName, text: "#,First name,Last name\n3,Test,Player 33\n4,Test,Player 4\n")
        addTeardownBlock {
            iPhoneFiles.remove(replaceName)
            iPhoneFiles.remove(mergeName)
        }
        let team = "iPT Roster Import \(Int.random(in: 100...999))"
        let gameID = try await openRoster(kit, team: team)
        addTeardownBlock { await api.deleteGame(gameID) }

        try pickFile(kit, replaceName)
        // Saved: the page's "Roster saved" banner; the summary is under the import controls.
        XCTAssertTrue(kit.wait(kit.any("Names and jersey matches update after the analysis runs again"), 15), "the import did not save")
        let summary = kit.any("Imported 3 players from \(replaceName)")
        kit.scrollIntoView(summary, maxSwipes: 6)
        XCTAssertTrue(summary.exists, "no import summary")
        kit.shot("replaced")
        var roster = try await api.iPhoneRoster(gameID, side: "scouted")
        XCTAssertEqual(((roster["players"] as? [[String: Any]]) ?? []).count, 3, "Replace did not replace the roster")

        let mode = app.buttons["When importing, Replace this roster"].firstMatch
        kit.scrollIntoView(mode)
        kit.tap(mode)
        kit.tap(app.buttons["Merge (update matching jerseys)"].firstMatch, timeout: 5)
        XCTAssertTrue(kit.wait(app.buttons["When importing, Merge (update matching jerseys)"].firstMatch, 5))
        try pickFile(kit, mergeName)
        let mergeSummary = kit.any("Imported 2 players from \(mergeName)")
        kit.pause(2)
        kit.scrollIntoView(mergeSummary, maxSwipes: 6)
        XCTAssertTrue(kit.wait(mergeSummary, 10), "no merge summary")
        kit.shot("merged")
        roster = try await api.iPhoneRoster(gameID, side: "scouted")
        let players = (roster["players"] as? [[String: Any]]) ?? []
        XCTAssertEqual(players.count, 4, "Merge did not keep the other players")
        XCTAssertEqual(players.first { ($0["jersey"] as? String) == "3" }?["last_name"] as? String, "Player 33", "Merge did not update #3")
    }

    /// "Choose file…" → Files → On My iPhone → `name`.
    @MainActor
    private func pickFile(_ kit: iPhoneKit, _ name: String) throws {
        let app = kit.app
        let choose = app.buttons["Choose file…"].firstMatch
        kit.scrollIntoView(choose)
        kit.tap(choose)
        let base = (name as NSString).deletingPathExtension
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", base)).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.waitForExistence(timeout: 5) { browse.tap() }
            let onMyPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
            if onMyPhone.waitForExistence(timeout: 5) { onMyPhone.tap() }
        }
        guard file.waitForExistence(timeout: 10) else {
            kit.shot("file-picker")
            throw XCTSkip("The Files picker does not show \(name) (On My iPhone).")
        }
        kit.shot("file-picker")
        file.tap()
    }

    /// "Download roster template" downloads the template and offers to save it in Files. Today the app
    /// crashes there: SwiftUI's fileExporter(item:) throws in NSFileWrapper.setPreferredFilename (SIGABRT).
    @MainActor
    func testTemplateDownload() async throws {
        let kit = try iPhoneKit(self, tag: "roster-template")
        let app = kit.app
        let api = kit.api
        let team = "iPT Roster Template \(Int.random(in: 100...999))"
        let gameID = try await openRoster(kit, team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.tap(app.buttons["Download roster template"].firstMatch)
        let save = app.buttons["DOCPicker.actionButton"].firstMatch
        _ = save.waitForExistence(timeout: 10)
        kit.shot("after-template-tap")
        // Not kit.expectBug: the test must end at the expected failure while the app is gone. Going on, XCTest
        // reports "BasketballScout crashed" after the block, as a failure of its own.
        XCTExpectFailure("bug: Download roster template crashes the app (NSFileWrapper setPreferredFilename in fileExporter(item:))") {
            XCTAssertEqual(app.state, .runningForeground, "the app is gone after Download roster template")
            XCTAssertTrue(save.exists, "the template was not offered to Files")
        }
        if save.exists {
            kit.tap(app.navigationBars.buttons["Cancel"].firstMatch)
            XCTAssertTrue(kit.waitGone(save, 10))
        }
    }

    /// Jersey assignments: mark a track "Not a player", then "Save & re-run analysis" saves it, starts the
    /// re-analysis and returns to the game page (05 §7.7).
    @MainActor
    func testJerseyAssignmentSaveAndRerun() async throws {
        let kit = try iPhoneKit(self, tag: "roster-tracks")
        let app = kit.app
        let api = kit.api
        let team = "iPT Roster Tracks \(Int.random(in: 100...999))"
        let gameID = try await openRoster(kit, team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.tap(app.buttons["Jersey assignments"].firstMatch)
        let track = kit.buttonStarting("Track ")
        XCTAssertTrue(kit.wait(track, 10), "no tracks")
        let saveAndRerun = app.buttons["Save & re-run analysis"].firstMatch
        XCTAssertTrue(saveAndRerun.exists)
        XCTAssertFalse(saveAndRerun.isEnabled, "Save & re-run analysis is enabled with nothing to save")
        let trackLabel = track.label
        kit.tap(track)
        // The track's own screen: what the server knows about it, then "Assign to" (a list of choices).
        let assign = app.buttons["Assign to"].firstMatch
        XCTAssertTrue(kit.wait(assign, 10), "the track screen has no Assign to")
        XCTAssertTrue((assign.value as? String ?? "").hasPrefix("Automatic"), "a new track is not on Automatic")
        kit.shot("track")
        kit.tap(assign)
        let notAPlayer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Not a player'")).firstMatch
        XCTAssertTrue(kit.wait(notAPlayer, 10), "no Not a player choice")
        kit.shot("choices")
        kit.tap(notAPlayer)
        // Choosing goes back to the track, which now says what was chosen.
        XCTAssertTrue(kit.wait(assign, until: "value BEGINSWITH 'Not a player'", 10), "the track does not show the choice")
        kit.shot("chosen")
        kit.back()
        XCTAssertTrue(kit.wait(kit.any("1 unsaved change"), 5), "no unsaved count")
        XCTAssertTrue(saveAndRerun.isEnabled)
        kit.shot("pending")
        saveAndRerun.tap()
        XCTAssertTrue(kit.wait(app.buttons["Game actions"].firstMatch, 15), "Save & re-run did not return to the game page")
        XCTAssertTrue(kit.wait(kit.any("Re-running the analysis"), 10), "no Re-running toast or panel")
        kit.shot("rerun")
        let tracks = try await api.send("GET", "/api/games/\(gameID)/tracks") as? [String: Any]
        let overrides = (tracks?["overrides"] as? [[String: Any]]) ?? []
        XCTAssertEqual(overrides.count, 1, "the track choice was not saved (\(trackLabel))")
        try await api.iPhoneWaitLatestJob(gameID, status: ["succeeded"], timeout: 90)
        let latest = try await api.iPhoneJobs(gameID).first
        XCTAssertEqual(latest?["kind"] as? String, "reanalyze")
    }
}
#endif
