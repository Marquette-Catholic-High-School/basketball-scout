import XCTest

/// Court calibration on iPad (04 §6.3): place four landmarks on a frame, save, see the fit and the
/// analysis offer, remove the calibration. The test film is 640×360 with the court's baselines at x = 30 and
/// x = 610, the near sideline at y = 320 and the lane lines at y = 135 / 225.
final class iPadCalibrationUITests: XCTestCase {
    @MainActor
    private func openCalibration(_ driver: ScoutAppDriver, team: String) async throws -> (id: String, frame: XCUIElement) {
        let film = try iPadLongFilm.url()
        let id = try await driver.api.iPadUploadedGame(scoutedTeam: team, film: film)
        driver.iPadLaunch(self)
        driver.iPadOpenGame("\(team) vs Test Opponent")
        let calibrate = driver.app.buttons["Calibrate court"].firstMatch
        XCTAssertTrue(calibrate.waitForExistence(timeout: 30), "no Calibrate court")
        XCTAssertTrue(driver.iPadWaitHittable(calibrate, timeout: 10))
        calibrate.tap()
        XCTAssertTrue(driver.app.navigationBars["Court calibration"].waitForExistence(timeout: 15), "the sheet did not open")
        let frame = driver.app.buttons["Film frame"].firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 20), "no frame")
        XCTAssertTrue(driver.iPadWaitGone(driver.app.staticTexts["Loading the frame…"], timeout: 20), "the frame did not load")
        driver.iPadWait(1)
        return (id, frame)
    }

    /// Taps film pixel (x, y) and waits for the point count to reach `count`. A tap on the frame is sometimes
    /// ignored (bug: `CalibrationFrameCanvas.dragEnded` drops a tap whose drag never reported a change), so one
    /// more tap is allowed and the miss is recorded as a known issue.
    @MainActor
    private func place(_ driver: ScoutAppDriver, _ frame: XCUIElement, x: CGFloat, y: CGFloat, count: Int,
                       file: StaticString = #filePath, line: UInt = #line) {
        let counted = driver.app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "\(count) of at least 4 points", "\(count) points - ready to save")).firstMatch
        driver.iPadTapPicture(in: frame, x: x, y: y)
        if !counted.waitForExistence(timeout: 3) {
            iPadKnownBug("bug: a tap on the calibration frame was ignored", strict: false) {
                XCTFail("the tap at film pixel (\(Int(x)), \(Int(y))) placed no point")
            }
            driver.snapshot("tap ignored L")
            driver.iPadTapPicture(in: frame, x: x, y: y)
        }
        XCTAssertTrue(counted.waitForExistence(timeout: 5), "point \(count) was not placed", file: file, line: line)
    }

    @MainActor
    func testPlaceFourPointsSaveAndRemove() async throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        let api = driver.api
        let (id, frame) = try await openCalibration(driver, team: "Test Court Elks")
        addTeardownBlock { await api.deleteGame(id) }
        driver.expectText("For fixed cameras only")
        driver.expectText("0 of at least 4 points. Spread them over the court; don't put them all on one line.")
        XCTAssertFalse(app.buttons["Save calibration"].isEnabled, "Save is enabled without points")
        driver.snapshot("calibration open L")

        // The first landmark is selected when the sheet opens.
        place(driver, frame, x: 30, y: 320, count: 1)
        driver.iPadChooseLandmark("Left end: lane meets baseline (near side)")
        place(driver, frame, x: 30, y: 225, count: 2)
        driver.iPadChooseLandmark("Right end: baseline, near corner")
        place(driver, frame, x: 610, y: 320, count: 3)
        driver.iPadChooseLandmark("Right end: lane meets baseline (near side)")
        place(driver, frame, x: 610, y: 225, count: 4)
        driver.expectText("4 points - ready to save")
        XCTAssertTrue(app.buttons["Remove point 4"].exists)
        driver.snapshot("four points L")

        // The page behind the sheet has its own "Analyze film" in the toolbar.
        let analyzeButtons = app.buttons.matching(NSPredicate(format: "label == 'Analyze film'"))
        let analyzeBefore = analyzeButtons.count
        app.buttons["Save calibration"].firstMatch.tap()
        driver.expectText("fit (average error", timeout: 20)
        driver.expectText("Check that the orange court lines drawn on the frame sit on the real lines.")
        // The game has film but no GPU results yet, so the offer is "Analyze film".
        driver.iPadWait(1)
        XCTAssertEqual(analyzeButtons.count, analyzeBefore + 1, "no Analyze film offer in the result")
        driver.snapshot("saved L")
        let saved = try await api.iPadGame(id)
        XCTAssertNotNil(saved["calibration"] as? [String: Any], "the calibration was not saved")

        driver.tapButton("Remove saved calibration")
        driver.expectText("Remove the saved court calibration for this game?")
        app.alerts.buttons["Remove"].firstMatch.tap()
        driver.expectText("Calibration removed. The analysis will use automatic court detection.", timeout: 20)
        driver.snapshot("removed L")
        let removed = try await api.iPadGame(id)
        XCTAssertTrue(removed["calibration"] == nil || removed["calibration"] is NSNull, "the calibration is still saved")
        driver.tapButton("Close")
        XCTAssertTrue(driver.iPadWaitGone(app.navigationBars["Court calibration"], timeout: 10))
        driver.iPadRotate(.portrait)
    }
}
