#if os(iOS)
import XCTest

/// Court calibration on iPhone (04 §5, §6.3): the sheet, choosing landmarks, tapping them on the frame,
/// Save and the verdict with the re-run offer, reopening on the saved calibration, Remove.
///
/// The test film (`ScoutUITestFilm`, 640 × 360) draws a court rectangle from (30, 40) to (610, 320) with
/// lanes 110 px deep and 90 px tall around y = 180, so landmark pixels are known exactly.
final class iPhoneCalibrationTests: XCTestCase {
    /// A landmark and where it is on the test film, as a fraction of the frame.
    private struct Point {
        let label: String
        let x: Double
        let y: Double
    }

    /// Four landmarks of the left end, not three on one line, clear of the frame's overlays (caption top
    /// left, zoom buttons top right) and near the top of the "Landmark to tap" menu (its later items are
    /// only built when the menu is scrolled).
    private let points = [
        Point(label: "Left end: baseline, near corner", x: 30.0 / 640, y: 320.0 / 360),
        Point(label: "Left end: lane meets baseline (far side)", x: 30.0 / 640, y: 135.0 / 360),
        Point(label: "Left end: free-throw line, near elbow", x: 140.0 / 640, y: 225.0 / 360),
        Point(label: "Left end: free-throw line, far elbow", x: 140.0 / 640, y: 135.0 / 360),
    ]

    /// Opens the sheet from the player toolbar and waits for the frame.
    @MainActor
    private func openSheet(_ kit: iPhoneKit) -> XCUIElement {
        let calibrate = kit.app.buttons["Calibrate court"].firstMatch
        kit.scrollIntoView(calibrate)
        kit.tap(calibrate)
        XCTAssertTrue(kit.wait(kit.app.navigationBars["Court calibration"], 10), "no Court calibration sheet")
        let frame = kit.app.buttons["Film frame"].firstMatch
        XCTAssertTrue(kit.wait(frame, 15), "no film frame")
        XCTAssertTrue(kit.waitGone(kit.any("Loading the frame"), 15))
        return frame
    }

    /// Chooses `label` in the "Landmark to tap" menu.
    @MainActor
    private func choose(_ kit: iPhoneKit, _ label: String) {
        let picker = kit.buttonStarting("Landmark to tap")
        kit.tap(picker)
        let option = kit.app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + " (")).firstMatch
        kit.tap(option, timeout: 5)
    }

    /// Taps the frame at `offset` and waits for the panel to list point `number`. The frame sometimes
    /// ignores a tap (reported; the iPad tester saw it too): then it takes a screenshot and taps once more.
    @MainActor
    private func place(_ kit: iPhoneKit, on frame: XCUIElement, at offset: CGVector, number: Int, label: String? = nil) {
        let listed = kit.any(label.map { "\(number). \($0)" } ?? "\(number). ")
        let spot = frame.coordinate(withNormalizedOffset: offset)
        spot.tap()
        if !kit.wait(listed, 4) {
            kit.shot("tap-ignored-point-\(number)")
            spot.tap()
        }
        XCTAssertTrue(kit.wait(listed, 5), "point \(number) was not placed")
    }

    /// Place four landmarks, save: the verdict and the re-run offer; reopen on the saved calibration and
    /// remove it (asks first).
    @MainActor
    func testCalibrateSaveReopenAndRemove() async throws {
        let kit = try iPhoneKit(self, tag: "calibrate")
        let app = kit.app
        let api = kit.api
        let team = "iPT Calibrate \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let frame = openSheet(kit)
        XCTAssertTrue(kit.any("For fixed cameras only").exists)
        let save = app.buttons["Save calibration"].firstMatch
        XCTAssertFalse(save.isEnabled, "Save is enabled without points")
        kit.shot("sheet")
        // Frame choice: the step buttons move through the film (the page's own buttons are behind the sheet).
        XCTAssertTrue(kit.any("0:00.00 / 0:12").exists, "the frame is not at the start of the film")
        let forward = app.buttons.matching(NSPredicate(format: "label == 'Forward 5 seconds'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(forward, "no Forward 5 seconds in the sheet").tap()
        XCTAssertTrue(kit.wait(kit.any("0:05.00 / 0:12"), 10), "Forward 5 seconds did not move the frame")
        let back = app.buttons.matching(NSPredicate(format: "label == 'Back 5 seconds'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(back, "no Back 5 seconds in the sheet").tap()
        XCTAssertTrue(kit.wait(kit.any("0:00.00 / 0:12"), 10), "Back 5 seconds did not move the frame back")
        for (index, point) in points.enumerated() {
            choose(kit, point.label)
            place(kit, on: frame, at: CGVector(dx: point.x, dy: point.y), number: index + 1, label: point.label)
        }
        XCTAssertTrue(kit.any("4 points - ready to save").exists)
        XCTAssertFalse(kit.any("The points are all on one line").exists)
        kit.shot("four-points")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let verdict = kit.any("average error")
        XCTAssertTrue(kit.wait(verdict, 15), "no verdict after saving")
        XCTAssertTrue(kit.buttonStarting("Re-run analysis").exists, "the result does not offer Re-run analysis")
        kit.shot("saved")
        let game = try await api.iPhoneGame(gameID)
        let calibration = try XCTUnwrap(game["calibration"] as? [String: Any], "the server has no calibration")
        XCTAssertEqual((calibration["points"] as? [Any])?.count, 4)
        XCTAssertEqual(calibration["video_width"] as? Int, 640)
        XCTAssertEqual(calibration["video_height"] as? Int, 360)

        // Close (nothing unsaved: no question), then reopen on the saved calibration and remove it.
        kit.tapButton("Close")
        XCTAssertTrue(kit.waitGone(app.navigationBars["Court calibration"], 5))
        _ = openSheet(kit)
        XCTAssertTrue(kit.wait(kit.any("average error"), 10), "the saved calibration is not shown when reopened")
        kit.shot("reopened")
        let remove = kit.button("Remove saved calibration")
        kit.scrollIntoView(remove)
        kit.tap(remove)
        XCTAssertTrue(kit.wait(app.alerts.firstMatch, 5), "Remove does not ask first")
        XCTAssertTrue(app.alerts.staticTexts["Remove the saved court calibration for this game?"].exists)
        kit.tap(kit.alertButton("Remove"))
        kit.pause(2)
        kit.shot("removed")
        let after = try await api.iPhoneGame(gameID)
        XCTAssertTrue(after["calibration"] is NSNull || after["calibration"] == nil, "the calibration was not removed")
        kit.tapButton("Close")
    }

    /// Unsaved points: Close asks "Close without saving?".
    @MainActor
    func testCloseWithUnsavedPointsAsks() async throws {
        let kit = try iPhoneKit(self, tag: "calibrate-close")
        let api = kit.api
        let team = "iPT Calibrate Close \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let frame = openSheet(kit)
        place(kit, on: frame, at: CGVector(dx: points[0].x, dy: points[0].y), number: 1)
        kit.tapButton("Close")
        XCTAssertTrue(kit.wait(kit.any("Close without saving?"), 5), "closing with unsaved points does not ask")
        kit.shot("close-question")
        XCTAssertTrue(kit.alertButton("Keep editing").exists)
        kit.tap(kit.alertButton("Discard changes"))
        XCTAssertTrue(kit.waitGone(kit.app.navigationBars["Court calibration"], 5), "the sheet did not close")
    }

    /// After the first point the sheet picks the next landmark by itself. Following it, a coach places the
    /// left baseline's four points (corners and lane ends), which lie on one court line: the panel then says
    /// "ready to save" next to "The points are all on one line", Save stays enabled and the server rejects
    /// the calibration. The web alternates the court's ends instead (04 §6.3).
    @MainActor
    func testSuggestedLandmarksAreNotOnOneLine() async throws {
        let kit = try iPhoneKit(self, tag: "calibrate-advance")
        let api = kit.api
        let team = "iPT Calibrate Advance \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let frame = openSheet(kit)
        for (index, offset) in [(0.25, 0.5), (0.75, 0.5), (0.75, 0.85), (0.25, 0.85)].enumerated() {
            place(kit, on: frame, at: CGVector(dx: offset.0, dy: offset.1), number: index + 1)
        }
        kit.scrollIntoView(kit.any("4 points"))
        kit.shot("suggested-points")
        kit.expectBug("bug: the suggested landmarks after the first point are all on the left baseline (one court line)") {
            XCTAssertFalse(kit.any("The points are all on one line").exists, "the suggested landmarks lie on one line")
        }
    }
}
#endif
