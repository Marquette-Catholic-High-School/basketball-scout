import Foundation
import Testing
@testable import BasketballScout

/// The calibration wording: the web's texts (calibrate.js, game.js) and the app's formatting.
@MainActor
struct CalibrationTextTests {
    @Test func theResultTitleUsesTheWebsVerdictAndOneDecimal() throws {
        #expect(CalibrationText.resultTitle(try CalibrationFixtures.calibration()) == "Good fit (average error 1.5 ft)")
        #expect(CalibrationText.resultTitle(try CalibrationFixtures.calibration("calibration_put_minimal.json"))
            == "Excellent fit (average error 0.0 ft)")
        var calibration = try CalibrationFixtures.calibration()
        calibration.reprojectionErrorFt = 3.25
        #expect(CalibrationText.resultTitle(calibration) == "Fair fit - double-check the points (average error 3.3 ft)")
        calibration.reprojectionErrorFt = 7
        #expect(CalibrationText.resultTitle(calibration)
            == "Poor fit - some points are probably on the wrong landmark (average error 7.0 ft)")
    }

    @Test func theResultTextsAreTheWebs() {
        #expect(CalibrationText.resultMessage
            == "Check that the orange court lines drawn on the frame sit on the real lines. If they don't, move or remove points and save again.")
        #expect(CalibrationText.resultHint(fullRunAdvised: false) == "The new mapping is used the next time the analysis runs.")
        #expect(CalibrationText.resultHint(fullRunAdvised: true)
            == "The new mapping is used the next time the analysis runs. Free throws need a full re-analysis: it sends the film to the GPU again.")
    }

    @Test func theRemovalNoticeSaysWhatHappensNext() {
        #expect(CalibrationText.removeQuestion == "Remove the saved court calibration for this game?")
        #expect(CalibrationText.removed(rerunKind: .analyze) == "Calibration removed. The analysis will use automatic court detection.")
        #expect(CalibrationText.removed(rerunKind: .reanalyze)
            == "Calibration removed. Re-run the analysis to go back to automatic court detection.")
    }

    @Test func frameTimesShowHundredths() {
        #expect(CalibrationText.frameTime(nil) == "0:00.00")
        #expect(CalibrationText.frameTime(0) == "0:00.00")
        #expect(CalibrationText.frameTime(83.47) == "1:23.47")
        #expect(CalibrationText.frameTime(2.3) == "0:02.30")
        #expect(CalibrationText.frameTime(1.0 / 30) == "0:00.03")
        #expect(CalibrationText.frameTime(3725.5) == "1:02:05.50")
        #expect(CalibrationText.frameTime(-4) == "0:00.00")
        #expect(CalibrationText.position(83.47, of: 725) == "1:23.47 / 12:05")
        #expect(CalibrationText.position(1.5, of: nil) == "0:01.50")
    }

    @Test func pixelsAreRoundedLikeTheWebsList() {
        #expect(CalibrationText.pixelText(XY(x: 812.5, y: 433.4)) == "(813, 433)")
        #expect(CalibrationText.pixelText(XY(x: .nan, y: 1)) == "(\u{2013}, \u{2013})")
        #expect(CalibrationText.pointTitle(3, "Left end: free-throw line, near elbow") == "3. Left end: free-throw line, near elbow")
        #expect(CalibrationText.removePoint(3) == "Remove point 3")
    }
}
