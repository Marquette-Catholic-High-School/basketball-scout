#if os(iOS)
import XCTest

/// The Scouting report and Exports tabs on iPhone (03 §7.8–§7.9). The test server has no Anthropic key, so
/// generating a report shows the server's "Claude is not configured" error.
final class iPhoneReportExportsTests: XCTestCase {
    /// No report yet: the empty text, the Claude warning (Generate stays enabled), and Generate showing the
    /// server's 503 REPORT_NOT_CONFIGURED as an error box.
    @MainActor
    func testGenerateReportWithoutClaude() async throws {
        let kit = try iPhoneKit(self, tag: "report")
        let api = kit.api
        let health = try await api.iPhoneHealth()
        try XCTSkipIf((health["claude_configured"] as? Bool) != false, "the test server has Claude configured")
        let team = "iPT Report \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Scouting report")
        XCTAssertTrue(kit.wait(kit.any("Claude is not configured"), 5), "no Claude warning")
        XCTAssertTrue(kit.any("Scouting reports need an Anthropic API key.").exists)
        XCTAssertTrue(kit.any("No scouting report on ").exists, "no empty-report text")
        XCTAssertTrue(kit.any("Coach focus (optional)").exists)
        kit.shot("empty")
        let generate = kit.button("Generate report")
        kit.scrollIntoView(generate)
        XCTAssertTrue(generate.isEnabled, "Generate is disabled although the server decides")
        generate.tap()
        let error = kit.any("No Anthropic API key is set, so the scouting report cannot be written.")
        XCTAssertTrue(kit.wait(error, 10), "the server's error is not shown")
        kit.scrollIntoView(error)
        kit.shot("error")
        let jobs = try await api.iPhoneJobs(gameID)
        XCTAssertFalse(jobs.contains { ($0["kind"] as? String) == "report" }, "a report job was created")
    }

    /// Exports: copy the FastScout paste block ("Copied" notice), each download shows the downloaded file
    /// with Save to Files… (the system picker opens), Share… (the share sheet opens) and Done.
    @MainActor
    func testExportsCopyAndDownloads() async throws {
        let kit = try iPhoneKit(self, tag: "exports")
        let app = kit.app
        let api = kit.api
        let team = "iPT Exports \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        kit.selectTab("Exports")
        XCTAssertTrue(kit.wait(kit.any("FastScout Stats Database (Classic)"), 5))
        XCTAssertTrue(kit.any("FastScout Web custom table (CSV)").exists)
        XCTAssertTrue(kit.any("Other downloads").exists)
        let copy = kit.button("Copy FastScout paste block")
        kit.scrollIntoView(copy)
        kit.tap(copy)
        XCTAssertTrue(kit.wait(kit.any("In FastScout: Stats > Edit Stats Database > Box Score > Paste \(team) Data."), 5), "no Copied notice")
        kit.shot("copied")

        let download = kit.button("Download .txt")
        kit.scrollIntoView(download)
        kit.tap(download)
        let panel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'fastscout_' AND label CONTAINS '.txt'")).firstMatch
        XCTAssertTrue(kit.wait(panel, 10), "no downloaded file panel")
        XCTAssertTrue(kit.any("Downloaded · ").exists)
        kit.scrollIntoView(kit.button("Save to Files…"))
        kit.shot("downloaded")
        // Save to Files… opens the system picker; Cancel keeps the panel.
        kit.tapButton("Save to Files…")
        let saveButton = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(kit.wait(saveButton, 10), "Save to Files… did not open the Files picker")
        kit.shot("files-picker")
        kit.tap(app.navigationBars.buttons["Cancel"].firstMatch)
        XCTAssertTrue(kit.waitGone(saveButton, 10))
        // Share… opens the share sheet.
        let share = kit.button("Share…")
        kit.scrollIntoView(share)
        kit.tap(share)
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(kit.wait(sheet, 10), "Share… did not open the share sheet")
        kit.shot("share-sheet")
        // The share sheet closes with a tap above it.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        if !kit.waitGone(sheet, 5) { sheet.swipeDown() }
        XCTAssertTrue(kit.waitGone(sheet, 10), "the share sheet did not close")
        kit.tap(kit.button("Done"))
        XCTAssertTrue(kit.waitGone(panel, 5), "Done kept the file panel")

        // The other downloads.
        for (button, prefix, suffix) in [("Download CSV", "fastscout_", ".csv"), ("Timeline CSV", "timeline_", ".csv"), ("Analysis JSON", "analysis_", ".json")] {
            let item = kit.button(button)
            kit.scrollIntoView(item)
            kit.tap(item)
            let file = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", prefix, suffix)).firstMatch
            XCTAssertTrue(kit.wait(file, 10), "\(button) did not download")
            kit.scrollIntoView(file)
            kit.shot("downloaded-\(button)")
            let done = kit.button("Done")
            kit.scrollIntoView(done)
            kit.tap(done)
            XCTAssertTrue(kit.waitGone(file, 5))
        }
        // The panel appears at the top of the card: after a tap on a button further down it is off screen.
        let item = kit.button("Analysis JSON")
        kit.scrollIntoView(item)
        kit.tap(item)
        let file = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'analysis_'")).firstMatch
        XCTAssertTrue(kit.wait(file, 10))
        kit.pause(1)
        kit.shot("after-analysis-json-tap")
        kit.expectBug("bug: a download's file panel appears at the top of the Exports card, off screen when the button that started it is lower down") {
            XCTAssertTrue(kit.isVisible(file), "the downloaded file panel is off screen")
        }
    }
}
#endif
