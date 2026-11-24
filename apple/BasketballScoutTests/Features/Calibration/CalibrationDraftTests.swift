import Foundation
import Testing
@testable import BasketballScout

/// Placing, moving and removing points; the selection; warnings; saved calibrations in another copy's pixels;
/// the request body (04 §5.2, §6.3, §8.17–8.19; calibrate.js).
@MainActor
struct CalibrationDraftTests {
    private let small = CalibrationFrameSize(width: 640, height: 360)
    private let large = CalibrationFrameSize(width: 1280, height: 720)

    private func makeDraft(court: CourtDimensions? = nil) throws -> CalibrationDraft {
        let landmarks = try court.map { CalibrationPreviewData.landmarks(court: $0) } ?? CalibrationFixtures.landmarks()
        var draft = CalibrationDraft(landmarks: landmarks.landmarks)
        draft.fit(to: small)
        return draft
    }

    /// Places `name` at `pixel` (selecting it first).
    private func place(_ name: String, _ x: Double, _ y: Double, in draft: inout CalibrationDraft) {
        draft.selectedLandmark = name
        draft.place(at: XY(x: x, y: y))
    }

    @Test func aNewDraftStartsAtTheFirstLandmark() throws {
        let draft = try makeDraft()
        #expect(draft.landmarks.count == 25)
        #expect(draft.selectedLandmark == "left_baseline_near_corner")
        #expect(draft.countText == "0 of at least 4 points. Spread them over the court; don't put them all on one line.")
        #expect(!draft.canSave && !draft.isDirty && !draft.canUndo)
        #expect(draft.matrix == nil && draft.tip == nil && draft.warnings.isEmpty)
    }

    @Test func placingKeepsATenthOfAPixelAndMovesOnAtTheSameEnd() throws {
        var draft = try makeDraft()
        let placed = draft.place(at: XY(x: 40, y: 330))
        #expect(placed)
        #expect(draft.points == [CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 40, y: 330))])
        // 04 §8.17: within the end being worked on (the web would jump to the right end here).
        #expect(draft.selectedLandmark == "left_baseline_far_corner")
        draft.place(at: XY(x: 150.04, y: 120.06))
        #expect(draft.points[1] == CalibrationPoint(landmark: "left_baseline_far_corner", px: XY(x: 150, y: 120.1)))
        #expect(draft.selectedLandmark == "left_lane_baseline_near")
        #expect(draft.number(of: "left_baseline_far_corner") == 2)
        #expect(draft.isDirty && draft.canUndo)
    }

    @Test func theSelectionSkipsTheSpotOfAPlacedPointThenGoesToTheOtherEnd() throws {
        var draft = try makeDraft()
        let leftEnd = [
            "left_baseline_near_corner", "left_baseline_far_corner", "left_lane_baseline_near", "left_lane_baseline_far",
            "left_ft_line_near", "left_ft_line_far", "left_ft_circle_top", "left_three_corner_near", "left_three_corner_far",
        ]
        for (index, name) in leftEnd.enumerated() {
            #expect(draft.selectedLandmark == name)
            draft.place(at: XY(x: Double(10 + index * 30), y: Double(100 + index * 10)))
        }
        // left_three_top is the same spot as left_ft_circle_top on this court (04 §8.18): skipped.
        #expect(draft.selectedLandmark == "right_baseline_near_corner")
        #expect(draft.sameSpotLandmarks(as: "left_ft_circle_top").map(\.name) == ["left_three_top"])
    }

    @Test func placingAPlacedLandmarkAgainMovesItsPoint() throws {
        var draft = try makeDraft()
        draft.place(at: XY(x: 40, y: 330))
        draft.place(at: XY(x: 150, y: 120))
        draft.selectedLandmark = "left_baseline_near_corner"
        draft.place(at: XY(x: 42, y: 331))
        #expect(draft.points.count == 2)
        #expect(draft.points[0] == CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 42, y: 331)))
        #expect(draft.number(of: "left_baseline_near_corner") == 1)
        #expect(draft.selectedLandmark == "left_lane_baseline_near")
    }

    @Test func nothingIsPlacedWithoutALandmarkOrAPixel() throws {
        var draft = try makeDraft()
        draft.selectedLandmark = nil
        let withoutLandmark = draft.place(at: XY(x: 1, y: 1))
        #expect(!withoutLandmark)
        draft.selectedLandmark = "center"
        let withoutPixel = draft.place(at: XY(x: .nan, y: 1))
        #expect(!withoutPixel)
        #expect(draft.points.isEmpty && !draft.canUndo)
    }

    @Test func theCountLineIsTheWebs() {
        #expect(CalibrationText.count(0) == "0 of at least 4 points. Spread them over the court; don't put them all on one line.")
        #expect(CalibrationText.count(3) == "3 of at least 4 points. Spread them over the court; don't put them all on one line.")
        #expect(CalibrationText.count(4) == "4 points - ready to save (more points spread over the court make it more accurate).")
        #expect(CalibrationText.count(7) == "7 points - ready to save (more points spread over the court make it more accurate).")
    }

    @Test func fourOrFivePointsGetTheTipAndFourCanBeSaved() throws {
        var draft = try makeDraft()
        for (index, name) in ["left_baseline_near_corner", "left_baseline_far_corner", "midcourt_near"].enumerated() {
            place(name, Double(index * 50), 100, in: &draft)
        }
        #expect(draft.tip == nil && !draft.canSave)
        place("midcourt_far", 300, 50, in: &draft)
        #expect(draft.tip == CalibrationText.fewPointsTip && draft.canSave)
        place("center", 300, 150, in: &draft)
        #expect(draft.tip != nil)
        place("right_baseline_near_corner", 600, 300, in: &draft)
        #expect(draft.tip == nil)
        #expect(draft.countText == "6 points - ready to save (more points spread over the court make it more accurate).")
    }

    @Test func undoGoesBackOneChangeAtATime() throws {
        var draft = try makeDraft()
        draft.place(at: XY(x: 10, y: 10))
        draft.place(at: XY(x: 20, y: 20))
        draft.place(at: XY(x: 30, y: 30))
        let three = draft.points
        draft.remove(three[1].landmark)
        draft.clear()
        #expect(draft.points.isEmpty)
        #expect(draft.selectedLandmark == "left_baseline_near_corner")
        draft.undo()
        #expect(draft.points == [three[0], three[2]])
        draft.undo()
        #expect(draft.points == three)
        draft.undo()
        draft.undo()
        draft.undo()
        #expect(draft.points.isEmpty && !draft.canUndo)
        draft.undo()
        #expect(draft.points.isEmpty)
    }

    @Test func aDragIsOneUndoStep() throws {
        var draft = try makeDraft()
        draft.place(at: XY(x: 40, y: 330))
        draft.place(at: XY(x: 150, y: 120))
        draft.beginMove()
        draft.setPosition(of: "left_baseline_near_corner", to: XY(x: 50, y: 340))
        draft.setPosition(of: "left_baseline_near_corner", to: XY(x: 60, y: 345.55))
        draft.endMove()
        #expect(draft.point(for: "left_baseline_near_corner")?.px == XY(x: 60, y: 345.6))
        draft.undo()
        #expect(draft.point(for: "left_baseline_near_corner")?.px == XY(x: 40, y: 330))
        #expect(draft.points.count == 2)
    }

    @Test func aDragInterruptedByAPinchPutsThePointBack() throws {
        var draft = try makeDraft()
        draft.place(at: XY(x: 40, y: 330))
        draft.beginMove()
        draft.setPosition(of: "left_baseline_near_corner", to: XY(x: 90, y: 90))
        draft.cancelMove()
        #expect(draft.point(for: "left_baseline_near_corner")?.px == XY(x: 40, y: 330))
        draft.undo()
        #expect(draft.points.isEmpty)
    }

    @Test func twoPointsOnOneCourtSpotAreWarned() throws {
        var draft = try makeDraft()
        place("left_ft_circle_top", 200, 200, in: &draft)
        #expect(draft.warnings.isEmpty)
        place("left_three_top", 230, 205, in: &draft)
        #expect(draft.warnings == [CalibrationWarning(
            id: "same-spot:left_ft_circle_top:left_three_top",
            title: "Two points mark the same spot",
            message: "Left end: top of the free-throw circle (point 1) and Left end: top of the 3-point arc (point 2) are the same spot on this court. Remove one of them.")])
    }

    @Test func onAnotherCourtTheTwoTopsAreDifferentSpots() throws {
        var court = CourtDimensions.nfhs
        court.threePointRadiusFt = 20.75  // the top of the arc is 26 ft from the baseline, the circle's 25 ft
        var draft = try makeDraft(court: court)
        #expect(draft.sameSpotLandmarks(as: "left_ft_circle_top").isEmpty)
        place("left_ft_circle_top", 200, 200, in: &draft)
        place("left_three_top", 230, 205, in: &draft)
        #expect(draft.warnings.isEmpty)
    }

    @Test func pointsOnOneLineAreWarned() throws {
        var draft = try makeDraft()
        place("left_baseline_near_corner", 40, 330, in: &draft)
        place("left_lane_baseline_near", 80, 260, in: &draft)
        #expect(draft.warnings.isEmpty)
        place("left_lane_baseline_far", 100, 200, in: &draft)
        place("left_baseline_far_corner", 150, 120, in: &draft)
        #expect(draft.warnings.map(\.id) == ["one-line"])
        #expect(draft.warnings.first?.title == "The points are all on one line")
        place("left_ft_line_near", 200, 250, in: &draft)
        #expect(draft.warnings.isEmpty)
    }

    @Test func theRequestCarriesTheCopysSizeAndTheFrameTime() throws {
        var draft = try makeDraft()
        draft.fit(to: large)
        place("left_baseline_near_corner", 80, 660, in: &draft)
        place("left_baseline_far_corner", 300.04, 240, in: &draft)
        place("midcourt_near", 640, 684, in: &draft)
        place("midcourt_far", 640, 224, in: &draft)
        let request = draft.request(frameTime: 12.5)
        #expect(request.frameT == 12.5)
        #expect(request.videoWidth == 1280 && request.videoHeight == 720)
        #expect(request.points.map(\.landmark) == ["left_baseline_near_corner", "left_baseline_far_corner", "midcourt_near", "midcourt_far"])
        #expect(request.points[1].px == XY(x: 300, y: 240))
        #expect(draft.request(frameTime: -1).frameT == 0)
        #expect(draft.request(frameTime: .nan).frameT == nil)
        #expect(draft.request(frameTime: nil).frameT == nil)

        let body = try #require(try JSONSerialization.jsonObject(with: ScoutJSON.encode(request)) as? [String: Any])
        #expect(Set(body.keys) == ["points", "frame_t", "video_width", "video_height"])
        #expect(body["video_width"] as? Int == 1280)
        let first = try #require((body["points"] as? [[String: Any]])?.first)
        #expect(first["landmark"] as? String == "left_baseline_near_corner")
        #expect(first["px"] as? [Double] == [80, 660])
    }

    @Test func withoutAFrameTheSizeIsLeftOut() throws {
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.place(at: XY(x: 1, y: 2))
        let request = draft.request(frameTime: 1)
        #expect(request.videoWidth == nil && request.videoHeight == nil)
    }

    @Test func aSavedCalibrationIsShownInThePixelsOfTheCopyOnScreen() throws {
        let saved = try CalibrationFixtures.calibration()  // 640×360
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.load(saved, currentSize: large)
        #expect(draft.frameSize == large)
        #expect(draft.points[0].px == XY(x: 80, y: 660))
        #expect(draft.points[6].px == XY(x: 643, y: 366.5))
        #expect(draft.matrix?[0][0] == saved.matrix[0][0] / 2)
        #expect(draft.matrix?[1][2] == saved.matrix[1][2])
        #expect(!draft.isDirty && !draft.canUndo)
        // The first landmark without a point, in the documented order.
        #expect(draft.selectedLandmark == "left_lane_baseline_near")
    }

    @Test func aSavedCalibrationWithoutASizeIsInThePixelsOfTheCopyOnScreen() throws {
        let saved = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.load(saved, currentSize: nil)
        #expect(draft.frameSize == nil)
        draft.fit(to: small)
        #expect(draft.frameSize == small)
        #expect(draft.points == saved.points)
        #expect(draft.matrix == saved.matrix)

        var other = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        other.load(saved, currentSize: large)
        #expect(other.frameSize == large)
        #expect(other.points == saved.points)
    }

    @Test func anyChangeHidesTheFitUntilItIsSavedAgain() throws {
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.load(try CalibrationFixtures.calibration(), currentSize: small)
        #expect(draft.matrix != nil)
        draft.beginMove()
        draft.setPosition(of: "center", to: XY(x: 330, y: 190))
        draft.endMove()
        #expect(draft.matrix == nil && draft.isDirty)
        draft.undo()
        #expect(draft.matrix != nil && !draft.isDirty)
        draft.remove("center")
        #expect(draft.matrix == nil)
    }

    @Test func savingMakesTheSentPointsTheSavedOnes() throws {
        var draft = try makeDraft()
        for (index, name) in ["left_baseline_near_corner", "left_baseline_far_corner", "right_baseline_near_corner", "right_baseline_far_corner"].enumerated() {
            place(name, Double(40 + index * 150), Double(330 - index * 50), in: &draft)
        }
        let response = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        let request = draft.request(frameTime: 1)
        draft.didSave(response, sentPoints: request.points, sentSize: draft.frameSize)
        #expect(!draft.isDirty)
        #expect(draft.matrix == response.matrix)
    }

    @Test func aSaveAnsweredAfterTheCopyChangedIsRescaled() throws {
        var draft = try makeDraft()
        for (index, name) in ["left_baseline_near_corner", "left_baseline_far_corner", "right_baseline_near_corner", "right_baseline_far_corner"].enumerated() {
            place(name, Double(40 + index * 150), Double(330 - index * 50), in: &draft)
        }
        let request = draft.request(frameTime: 1)
        draft.fit(to: large)
        #expect(draft.points[1].px == XY(x: 380, y: 560))
        let response = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        draft.didSave(response, sentPoints: request.points, sentSize: small)
        #expect(!draft.isDirty)
        #expect(draft.matrix?[0][0] == response.matrix[0][0] / 2)
    }

    @Test func undoAfterTheCopyChangedComesBackInTheNewPixels() throws {
        var draft = try makeDraft()
        draft.place(at: XY(x: 40, y: 330))
        draft.place(at: XY(x: 150, y: 120))
        draft.fit(to: large)
        draft.undo()
        #expect(draft.points == [CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 80, y: 660))])
    }

    @Test func removingTheSavedCalibrationTakesThePointsWithIt() throws {
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.load(try CalibrationFixtures.calibration(), currentSize: small)
        draft.remove("center")
        draft.didRemoveSaved()
        #expect(draft.points.isEmpty && !draft.canUndo && !draft.isDirty)
        #expect(draft.matrix == nil)
        #expect(draft.selectedLandmark == "left_baseline_near_corner")
    }

    @Test func aCalibrationSavedElsewhereKeepsUnsavedPoints() throws {
        var draft = CalibrationDraft(landmarks: try CalibrationFixtures.landmarks().landmarks)
        draft.load(try CalibrationFixtures.calibration(), currentSize: small)
        draft.beginMove()
        draft.setPosition(of: "center", to: XY(x: 330, y: 190))
        draft.endMove()
        let edited = draft.points
        let other = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        draft.replaceSaved(other)
        #expect(draft.points == edited)
        #expect(draft.savedPoints == other.points)
        #expect(draft.isDirty && draft.matrix == nil)
    }

    @Test func unknownLandmarksAreNamedInWords() throws {
        let draft = try makeDraft()
        #expect(draft.label(for: "left_mystery_spot") == "Left end: mystery spot")
        #expect(draft.label(for: "center") == "Center of the court")
    }
}
