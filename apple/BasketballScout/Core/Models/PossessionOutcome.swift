import Foundation

/// `Possession.outcome` (01 §3). The server's own `unknown` value is `.unknownOutcome`; `.unknown(raw)` is
/// a value this app does not know. `foul` is defined but not produced today (06 §3.14).
nonisolated enum PossessionOutcome: ServerEnum {
    /// `"made_fg"`
    case madeFieldGoal
    /// `"missed_fg"`
    case missedFieldGoal
    case turnover
    /// `"free_throws"`
    case freeThrows
    case foul
    /// `"end_of_period"`
    case endOfPeriod
    /// `"unknown"`
    case unknownOutcome
    case unknown(String)

    static let knownCases: [PossessionOutcome] = [.madeFieldGoal, .missedFieldGoal, .turnover, .freeThrows, .foul, .endOfPeriod, .unknownOutcome]

    var rawValue: String {
        switch self {
        case .madeFieldGoal: "made_fg"
        case .missedFieldGoal: "missed_fg"
        case .turnover: "turnover"
        case .freeThrows: "free_throws"
        case .foul: "foul"
        case .endOfPeriod: "end_of_period"
        case .unknownOutcome: "unknown"
        case .unknown(let rawValue): rawValue
        }
    }
}
