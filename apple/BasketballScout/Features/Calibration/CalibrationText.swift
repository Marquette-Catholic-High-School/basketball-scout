import Foundation

/// The calibration sheet's wording. Texts the web shows are quoted word for word (calibrate.js, game.html:96-122,
/// game.js:286-306; 04 §6.3); "click" becomes "tap" on iPhone and iPad. Shared label tables (landmark names and
/// groups, the fit verdict, the re-run button, the Full re-analysis confirmation) come from the models'
/// `Labels`/`+Derived` and are not repeated here. Texts the web does not have (warnings for 04 §8.17–8.19,
/// film notices) are the app's own, in the same plain tone.
nonisolated enum CalibrationText {
    // MARK: - Sheet

    static let title = "Court calibration"
    /// The web's heading is "Court calibration (fixed cameras only)" (game.html:98).
    static let fixedCamerasOnly = "For fixed cameras only"
    static let close = "Close"

    /// The panel's hint (game.html:101). On the Mac the arrow keys step through the film as on the web.
    static var hint: String {
        #if os(macOS)
        "Use this when the camera never moves. Find a frame where the floor lines are clear (arrow keys step through the film), pick a landmark, then click exactly where it is on the frame. Add at least 4 points spread across the court."
        #else
        "Use this when the camera never moves. Find a frame where the floor lines are clear (the slider and the step buttons move through the film), pick a landmark, then tap exactly where it is on the frame - pinch to zoom in. Add at least 4 points spread across the court."
        #endif
    }

    // MARK: - Unavailable

    static let noFilmTitle = "No film to calibrate on"
    /// calibrate.js:112 (the web's toast when the player has no film).
    static let noFilm = "Add film to this game before calibrating the court."
    /// 04 §8.16: a link film can only be calibrated on the GPU's annotated copy, which the first analysis makes.
    static let linkFilmWithoutCopy =
        "This film was added as a link, so it isn't stored on this server. You can calibrate on the annotated copy once the first analysis has made it."
    static let loadingGame = "Loading game\u{2026}"
    static let loadingLandmarks = "Loading court landmarks\u{2026}"
    static let loadingFrame = "Loading the frame\u{2026}"

    // MARK: - Film copy

    /// The original could not be decoded on this device; the GPU's copy is used instead (player.js:215-234).
    static let annotatedFallback = "The original film can't be shown here, so the annotated copy is used."
    /// 04 §8.16: link films are calibrated on the 720p annotated copy, which has the tracking overlays.
    static let linkFilmCopy = "This film was added as a link, so the annotated copy (with the tracking overlays) is shown."
    static let annotatedOnlyCopy = "The original film isn't stored on this server, so the annotated copy is shown."

    static let unreadableTitle = "The film can't be shown here"
    static let unreadableMessage = "This device could not decode the film at this point, so there is no frame to calibrate on."
    static let unreadableHint = "Try another moment in the film. If it keeps happening, re-export the film as H.264 MP4 and upload it again."
    static let filmFailedTitle = "Can't load the film"
    static let filmFailedMessage = "The frame could not be loaded from the server."
    static let filmFailedHint = "Check the network connection (or that the server is running) and try again."

    // MARK: - Frame and scrubber

    static let filmPosition = "Film position"
    static let backFiveSeconds = "Back 5 seconds"
    static let forwardFiveSeconds = "Forward 5 seconds"
    static let backOneSecond = "Back 1 second"
    static let forwardOneSecond = "Forward 1 second"
    static let previousFrame = "Previous frame"
    static let nextFrame = "Next frame"
    static let goToSavedFrame = "Go to the saved frame"
    static let zoomIn = "Zoom in"
    static let zoomOut = "Zoom out"
    static let zoomToFit = "Show the whole frame"
    static let frameLabel = "Film frame"

    static var frameHint: String {
        #if os(macOS)
        "Click where the selected landmark is to place its point. Drag a point to move it."
        #else
        "Tap where the selected landmark is to place its point. Drag a point to move it."
        #endif
    }

    /// calibrate.js:176 (the web's toast for a click outside the picture).
    static var outsidePicture: String {
        #if os(macOS)
        "Click inside the picture, on the selected landmark."
        #else
        "Tap inside the picture, on the selected landmark."
        #endif
    }

    /// The canvas caption for the landmark the next click places.
    static func placeCaption(_ label: String) -> String {
        #if os(macOS)
        "Click to place: \(label)"
        #else
        "Tap to place: \(label)"
        #endif
    }

    /// The canvas caption for a placed point.
    static func pointCaption(_ number: Int, _ label: String) -> String {
        "Point \(number): \(label)"
    }

    /// Film time with hundredths, for stepping frame by frame: "1:23.47" (whole seconds as `ScoutFormat.clock`).
    static func frameTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "0:00.00" }
        let hundredths = Int((min(seconds, 1e9) * 100 + 1e-6).rounded(.down))
        let fraction = hundredths % 100
        return ScoutFormat.clock(Double(hundredths / 100)) + "." + (fraction < 10 ? "0" : "") + "\(fraction)"
    }

    /// "1:23.47 / 12:05".
    static func position(_ seconds: Double?, of duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return frameTime(seconds) }
        return frameTime(seconds) + " / " + ScoutFormat.clock(duration)
    }

    // MARK: - Landmarks

    /// The landmark picker's label (game.html:105).
    static var landmarkPicker: String {
        #if os(macOS)
        "Landmark to click"
        #else
        "Landmark to tap"
        #endif
    }

    /// The diagram's labels (calibrate.js:354-355).
    static let farSideline = "Far sideline"
    static let nearSideline = "Near sideline (camera side)"
    static let courtDiagram = "Court diagram"

    /// The diagram's VoiceOver value (calibrate.js:350).
    static func selectedLandmark(_ label: String?) -> String {
        "Selected landmark: \(label ?? "")"
    }

    /// A picker option for a landmark that already has a point.
    static func placedOption(_ label: String, number: Int) -> String {
        "\(label) (point \(number))"
    }

    /// 04 §8.18: the selected landmark is the same court spot as another one.
    static func sameSpotNote(_ otherLabel: String, otherNumber: Int?) -> String {
        let point = otherNumber.map { " (point \($0))" } ?? ""
        return "Same spot on this court as \(otherLabel)\(point). Place only one of them."
    }

    // MARK: - Points

    /// The count line (calibrate.js:197-199).
    static func count(_ count: Int) -> String {
        let minimum = CalibrationRequest.minimumPoints
        return count >= minimum
            ? "\(count) points - ready to save (more points spread over the court make it more accurate)."
            : "\(count) of at least \(minimum) points. Spread them over the court; don't put them all on one line."
    }

    /// 04 §8.19, 09 R14: with exactly 4 points the error is always about 0, so encourage 6 or more.
    static let fewPointsTip =
        "Exactly 4 points always fit perfectly, even with a point on the wrong spot. Add 6 or more spread over the court, so the average error can show a mistake."
    static let unsavedChanges = "Changes not saved yet."
    static let pointsTitle = "Points"

    /// A row of the points list: "3. Left end: free-throw line, near elbow" (calibrate.js:200-201).
    static func pointTitle(_ number: Int, _ label: String) -> String {
        "\(number). \(label)"
    }

    /// Rounded pixels as the list shows them: "(812, 433)" (calibrate.js:201).
    static func pixelText(_ pixel: XY) -> String {
        guard pixel.isFinite else { return "(\(ScoutFormat.placeholder), \(ScoutFormat.placeholder))" }
        return "(\(Int(ScoutFormat.roundHalfUp(pixel.x))), \(Int(ScoutFormat.roundHalfUp(pixel.y))))"
    }

    static let remove = "Remove"

    /// The Remove button's VoiceOver label (calibrate.js:202).
    static func removePoint(_ number: Int) -> String {
        "Remove point \(number)"
    }

    static let removeSelectedPoint = "Remove the selected point"

    // MARK: - Warnings (04 §8.18, server check "not all on one line")

    static let sameSpotTitle = "Two points mark the same spot"

    static func sameSpot(_ first: String, _ firstNumber: Int, _ second: String, _ secondNumber: Int) -> String {
        "\(first) (point \(firstNumber)) and \(second) (point \(secondNumber)) are the same spot on this court. Remove one of them."
    }

    static let oneLineTitle = "The points are all on one line"
    static let oneLineMessage = "Add points away from that line: the court can't be mapped from points on one line."

    // MARK: - Buttons (game.html:114-118)

    static let undo = "Undo"
    static let clearPoints = "Clear points"
    static let save = "Save calibration"
    /// The toolbar's Save (VoiceOver and the tooltip say "Save calibration").
    static let saveShort = "Save"
    static let saving = "Saving\u{2026}"
    static let removeSaved = "Remove saved calibration"
    static let removing = "Removing\u{2026}"

    // MARK: - Remove (calibrate.js:277-290)

    static let removeQuestion = "Remove the saved court calibration for this game?"
    static let removeConfirm = "Remove"

    /// The notice after removing: no GPU results yet (the re-run would be an ANALYZE) or a re-run is needed.
    static func removed(rerunKind: JobKind) -> String {
        rerunKind == .analyze
            ? "Calibration removed. The analysis will use automatic court detection."
            : "Calibration removed. Re-run the analysis to go back to automatic court detection."
    }

    // MARK: - Result (calibrate.js:233-252)

    /// "Good fit (average error 1.5 ft)"; the verdict is `CourtCalibration.fitQuality`.
    static func resultTitle(_ calibration: CourtCalibration) -> String {
        "\(calibration.fitQuality.text) (average error \(ScoutFormat.toFixed(calibration.reprojectionErrorFt, digits: 1)) ft)"
    }

    static let resultMessage =
        "Check that the orange court lines drawn on the frame sit on the real lines. If they don't, move or remove points and save again."

    /// `fullRunAdvised`: the analysis found no free throws, so a GPU run with the calibration is offered.
    static func resultHint(fullRunAdvised: Bool) -> String {
        fullRunAdvised
            ? "The new mapping is used the next time the analysis runs. Free throws need a full re-analysis: it sends the film to the GPU again."
            : "The new mapping is used the next time the analysis runs."
    }

    static let fullReanalysis = "Full re-analysis"
    /// The confirming button of the Full re-analysis question.
    static let sendToGPU = "Send to GPU"
    static let starting = "Starting\u{2026}"

    // MARK: - Closing with changes

    static let closeQuestion = "Close without saving?"
    static let closeMessage = "The points you placed or moved since the last save will be lost."
    static let discardChanges = "Discard changes"
    static let keepEditing = "Keep editing"
}
