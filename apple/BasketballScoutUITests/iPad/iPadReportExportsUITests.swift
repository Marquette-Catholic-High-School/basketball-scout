import XCTest

/// Scouting report and exports on iPad (03 §7.8, §7.9). The test server has no Anthropic key, so generating a
/// report fails with the server's error.
final class iPadReportExportsUITests: XCTestCase {
    @MainActor
    private func openTab(_ tab: String, _ driver: ScoutAppDriver, team: String) async throws -> String {
        let film = try ScoutUITestFilm.url()
        let id = try await driver.api.iPadAnalysedGame(scoutedTeam: team, film: film, otherTeam: "Test Rivals")
        driver.iPadLaunch(self)
        driver.iPadOpenGame("\(team) vs Test Rivals")
        driver.tapButton("Hide Sidebar")
        XCTAssertTrue(driver.app.buttons[tab].waitForExistence(timeout: 30), "no \(tab) tab")
        driver.iPadScrollPage(by: 450)
        driver.iPadSelectTab(tab)
        return id
    }

    @MainActor
    func testGenerateReportShowsWhyItCannotBeWritten() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Scouting report", driver, team: "Test Report Jays")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("Claude is not configured")
        driver.expectText("Scouting reports need an Anthropic API key.")
        driver.expectText("Coach focus (optional)")
        driver.expectText("No scouting report on ")
        XCTAssertFalse(app.buttons["Download .md"].exists, "Download .md without a report")
        let generate = app.buttons["Generate report"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        XCTAssertTrue(generate.isEnabled, "Generate report is disabled without Claude (the web keeps it enabled)")
        generate.tap()
        // The server's own error (503 REPORT_NOT_CONFIGURED), word for word.
        driver.expectText("No Anthropic API key is set, so the scouting report cannot be written.", timeout: 20)
        driver.iPadScrollPage(by: 300)
        driver.snapshot("report error L")
        XCTAssertTrue(generate.isEnabled, "Generate report stayed disabled after the error")
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testExportsCopyAndDownload() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Exports", driver, team: "Test Export Jays")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("FastScout Stats Database (Classic)")
        driver.expectText("FastScout Web custom table (CSV)")
        driver.expectText("In FastScout Classic: Stats > Edit Stats Database > Box Score > Paste Test Export Jays Data.")
        XCTAssertTrue(app.otherElements["FastScout paste block"].waitForExistence(timeout: 15), "no paste block preview")

        driver.tapButton("Copy FastScout paste block")
        driver.expectText("Copied")
        driver.expectText("In FastScout: Stats > Edit Stats Database > Box Score > Paste Test Export Jays Data.")

        // Each download shows the file with Save to Files / Share / Done.
        let downloads: [(button: String, suffix: String)] = [
            ("Download .txt", ".txt"), ("Download CSV", ".csv"), ("Timeline CSV", ".csv"), ("Analysis JSON", ".json"),
        ]
        for download in downloads {
            driver.tapButton(download.button)
            let panel = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS 'Downloaded ·'", download.suffix)).firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 20), "no downloaded file after \(download.button)")
            XCTAssertTrue(app.buttons["Save to Files…"].exists)
            XCTAssertTrue(app.buttons["Share…"].exists)
            driver.snapshot("downloaded \(download.button) L")
            driver.tapButton("Done")
            XCTAssertTrue(driver.iPadWaitGone(panel, timeout: 5), "Done did not close the download panel")
        }
        driver.iPadRotate(.portrait)
    }

    @MainActor
    func testSaveToFilesOpensTheSystemSavePanel() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let id = try await openTab("Exports", driver, team: "Test Save Jays")
        addTeardownBlock { await api.deleteGame(id) }
        driver.tapButton("Timeline CSV")
        XCTAssertTrue(app.buttons["Save to Files…"].waitForExistence(timeout: 20))
        driver.tapButton("Save to Files…")
        // The system's export panel (a remote view: give it time to come up).
        let close = app.buttons["Cancel"].firstMatch
        let saveAs = driver.iPadAny("Save as")
        XCTAssertNotNil(driver.waitForAny([saveAs], timeout: 30), "the save panel did not open")
        driver.snapshot("save panel L")
        if close.exists { close.tap() }
        XCTAssertTrue(driver.iPadWaitGone(saveAs, timeout: 10), "the save panel did not close")
        driver.iPadRotate(.portrait)
    }
}
