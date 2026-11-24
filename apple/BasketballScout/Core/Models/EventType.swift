import Foundation

/// `TimelineEvent.type` (01 §3, 06 §3.14), in the web's filter order (labels.js:5-24).
nonisolated enum EventType: ServerEnum {
    /// `"shot_made"`
    case shotMade
    /// `"shot_missed"`
    case shotMissed
    /// `"ft_made"`
    case freeThrowMade
    /// `"ft_missed"`
    case freeThrowMissed
    /// `"oreb"`
    case offensiveRebound
    /// `"dreb"`
    case defensiveRebound
    case assist
    case steal
    case block
    case turnover
    case foul
    case screen
    case pass
    /// `"jump_ball"`
    case jumpBall
    /// `"period_start"`
    case periodStart
    /// `"period_end"`
    case periodEnd
    case timeout
    /// `"possession_change"`
    case possessionChange
    case unknown(String)

    static let knownCases: [EventType] = [.shotMade, .shotMissed, .freeThrowMade, .freeThrowMissed, .offensiveRebound, .defensiveRebound, .assist, .steal, .block, .turnover, .foul, .screen, .pass, .jumpBall, .periodStart, .periodEnd, .timeout, .possessionChange]

    var rawValue: String {
        switch self {
        case .shotMade: "shot_made"
        case .shotMissed: "shot_missed"
        case .freeThrowMade: "ft_made"
        case .freeThrowMissed: "ft_missed"
        case .offensiveRebound: "oreb"
        case .defensiveRebound: "dreb"
        case .assist: "assist"
        case .steal: "steal"
        case .block: "block"
        case .turnover: "turnover"
        case .foul: "foul"
        case .screen: "screen"
        case .pass: "pass"
        case .jumpBall: "jump_ball"
        case .periodStart: "period_start"
        case .periodEnd: "period_end"
        case .timeout: "timeout"
        case .possessionChange: "possession_change"
        case .unknown(let rawValue): rawValue
        }
    }
}
