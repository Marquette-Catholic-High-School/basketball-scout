import Foundation

/// A label and its value: the data quality facts (quality.js `fact`), the box score's summary line.
nonisolated struct StatsFact: Identifiable, Hashable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

/// A jersey the analysis read but no roster has (quality.js `unmatchedLabel`): "Test Team A #14" in the
/// team's colours, or the raw code for a side this app does not know.
nonisolated struct StatsUnmatchedJersey: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
    /// The team whose colours the chip takes; nil for an unknown side (neutral chip).
    let side: TeamSide?
}

/// One "Warnings from the analysis" notice (quality.js): title = the server's message, small text = code.
nonisolated struct StatsQualityWarning: Identifiable, Hashable, Sendable {
    let id: Int
    let warning: PipelineWarning
    /// The notice colour: info, warning, error → danger; unknown severities as warnings.
    var tone: StatusTone { warning.severity.tone }
    /// "Full re-analysis" goes with this warning (FREE_THROWS_NOT_DETECTED, quality.js `fullRunAction`).
    let offersFullReanalysis: Bool
}

/// What the Data quality tab shows (quality.js `renderQuality`; 06 §12, 03 §7.10).
nonisolated struct StatsDataQualityModel: Sendable {
    let facts: [StatsFact]
    /// "Manual calibration saved (average error 1.5 ft)", when the game has a calibration.
    let calibrationText: String?
    /// The court was mapped (no "The court was not mapped" notice).
    let isCourtMapped: Bool
    let unmatchedJerseys: [StatsUnmatchedJersey]
    let warnings: [StatsQualityWarning]

    /// - Parameters:
    ///   - teamName: the page's team names (analysis, else game, else "Scouted team" / "Opponent").
    init(analysis: GameAnalysis, game: Game?, teamName: (TeamSide) -> String) {
        let quality = analysis.dataQuality
        let video = analysis.video
        let pipeline = analysis.pipeline
        facts = [
            StatsFact(label: "Court mapped", value: quality.homographyAvailable ? "Yes" : "No (zones are estimates)"),
            // quality.js: anything but "court" reads as video pixels.
            StatsFact(label: "Coordinates", value: quality.coordMode == .court ? CoordMode.court.label : CoordMode.pixel.label),
            StatsFact(label: "Jersey match rate", value: ScoutFormat.percent(quality.jerseyMatchRate, digits: 0)),
            StatsFact(label: "Tracks assigned", value: "\(quality.tracksAssigned) of \(quality.tracksTotal)"),
            StatsFact(label: "Ball visible", value: "\(ScoutFormat.percent(quality.ballCoverage, digits: 0)) of frames"),
            StatsFact(label: "Average event confidence", value: ScoutFormat.percent(quality.eventConfidenceMean, digits: 0)),
            StatsFact(label: "Film", value: ScoutFormat.filmFacts(
                width: video.width, height: video.height, fps: video.fps, durationSeconds: video.durationS)),
            StatsFact(label: "Pipeline", value: Self.pipelineText(pipeline)),
        ]
        calibrationText = game?.calibration.map {
            "Manual calibration saved (average error \(ScoutFormat.number($0.reprojectionErrorFt, digits: 1)) ft)"
        }
        isCourtMapped = quality.homographyAvailable
        unmatchedJerseys = quality.unmatchedJerseys.enumerated().map { index, code in
            Self.unmatchedJersey(code, id: index, teamName: teamName)
        }
        let canRunAgain = game.map { $0.calibration != nil && $0.hasFilm } ?? false
        warnings = quality.warnings.enumerated().map { index, warning in
            StatsQualityWarning(
                id: index, warning: warning,
                offersFullReanalysis: canRunAgain && warning.code == PipelineWarning.freeThrowsNotDetectedCode)
        }
    }

    /// "openhoopvision 2.1 on A10G": name (or "?"), version and "on <gpu>", empty parts left out.
    static func pipelineText(_ pipeline: PipelineInfo) -> String {
        [pipeline.name.isEmpty ? "?" : pipeline.name, pipeline.version, pipeline.gpu.map { $0.isEmpty ? "" : "on \($0)" }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "scouted:#14" → "Test Team A #14" (a side this app does not know keeps the raw code).
    static func unmatchedJersey(_ code: String, id: Int, teamName: (TeamSide) -> String) -> StatsUnmatchedJersey {
        let parts = code.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let side = TeamSide(rawValue: parts.first ?? "")
        guard side.isKnown else { return StatsUnmatchedJersey(id: id, text: code, side: nil) }
        let jersey = parts.count > 1 ? parts[1] : ""
        let text = "\(teamName(side)) \(jersey)".trimmingCharacters(in: .whitespaces)
        return StatsUnmatchedJersey(id: id, text: text, side: side)
    }

    // MARK: - Texts (quality.js)

    static let notMappedTitle = "The court was not mapped"
    static let notMappedMessage = "Shot locations and zones are approximate. If the camera does not move (a fixed gym camera), you can map the court yourself."
    static let calibrateTitle = "Calibrate court"
    static let unmatchedTitle = "Jerseys not on a roster"
    static let rosterLinkTitle = "Add these players or fix jersey assignments on the roster page"
    static let allMatchedText = "Every jersey read matched a roster player."
    static let warningsTitle = "Warnings from the analysis"
    static let noWarningsText = "No warnings."
    static let fullReanalysisTitle = "Full re-analysis"

    /// The button's tooltip: busy → "An analysis is already running", else "Send the film to the GPU again"
    /// (`Game.fullReanalysisHelp`).
    static func fullReanalysisHelp(isBusy: Bool) -> String {
        isBusy ? Game.analysisRunningHelp : "Send the film to the GPU again"
    }
}
