import SwiftUI

/// Court calibration (04 §5, §6.3; 09 R14, D1 #11), presented in a sheet from the film player or the data
/// quality tab. Reads the game, its saved calibration and the court landmarks from `GameContext`.
///
/// The coach picks a frame where the floor lines are clear, clicks (taps) known court landmarks on it, saves
/// the points (`PUT /api/games/{id}/calibration`) and checks the fit: the court lines drawn back onto the frame
/// must sit on the real ones. Then the analysis can be re-run with the new mapping.
///
/// Present it with `.sheet { CalibrationView().environment(context) }`; it closes itself ("Close", or after
/// starting a re-run) and asks before closing with unsaved points. Pause the player while it is open.
struct CalibrationView: View {
    @Environment(GameContext.self) private var context

    init() {}

    var body: some View {
        CalibrationScreen(model: CalibrationModel(context: context))
    }
}

#Preview("Calibration – saved, wide") {
    CalibrationScreen(model: CalibrationPreviewData.model())
        .frame(width: 1100, height: 760)
}

#Preview("Calibration – new, dark") {
    CalibrationScreen(model: CalibrationPreviewData.model(game: CalibrationPreviewData.game(calibration: nil)))
        .preferredColorScheme(.dark)
}

#Preview("Calibration – compact, large type") {
    CalibrationScreen(model: CalibrationPreviewData.model())
        .frame(width: 390, height: 844)
        .dynamicTypeSize(.xxxLarge)
}

#Preview("Calibration – link film without a copy") {
    CalibrationScreen(model: CalibrationPreviewData.model(game: CalibrationPreviewData.game(
        calibration: nil, status: .uploaded, hasVideo: false, videoURL: "https://example.com/films/test-film.mp4",
        hasTracking: false)))
}
