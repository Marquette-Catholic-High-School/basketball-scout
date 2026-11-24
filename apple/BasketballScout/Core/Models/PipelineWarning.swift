import Foundation

/// Something the analysis could not do well (01 §4.9, 06 §12), in `DataQuality.warnings`.
///
/// `code` is an open set (GPU codes such as `NO_COURT_HOMOGRAPHY`, server codes `NO_ROSTER`,
/// `COURT_NOT_MAPPED`, `LOW_JERSEY_MATCH`, `FREE_THROWS_NOT_DETECTED`, fallback `WARNING`), so it is a plain
/// string. The web shows `message` as the title, `code` under it, coloured by `severity`.
nonisolated struct PipelineWarning: Codable, Hashable, Sendable {
    var code: String
    var message: String
    var severity: WarningSeverity

    enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case message
        case severity
    }

    init(code: String, message: String, severity: WarningSeverity = .warning) {
        self.code = code
        self.message = message
        self.severity = severity
    }

    /// The warning that gets a "Full re-analysis" button when the game has a calibration and film (06 §12).
    static let freeThrowsNotDetectedCode = "FREE_THROWS_NOT_DETECTED"
}
