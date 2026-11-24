import Foundation

/// `Play.outcome` (01 §3). The server's own `unknown` value is `.unknownOutcome`; `.unknown(raw)` is a value
/// this app does not know.
nonisolated enum PlayOutcome: ServerEnum {
    /// `"made_fg"`
    case madeFieldGoal
    /// `"missed_fg"`
    case missedFieldGoal
    case turnover
    case foul
    /// `"no_shot"`
    case noShot
    /// `"unknown"`
    case unknownOutcome
    case unknown(String)

    static let knownCases: [PlayOutcome] = [.madeFieldGoal, .missedFieldGoal, .turnover, .foul, .noShot, .unknownOutcome]

    var rawValue: String {
        switch self {
        case .madeFieldGoal: "made_fg"
        case .missedFieldGoal: "missed_fg"
        case .turnover: "turnover"
        case .foul: "foul"
        case .noShot: "no_shot"
        case .unknownOutcome: "unknown"
        case .unknown(let rawValue): rawValue
        }
    }
}
