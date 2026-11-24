import Foundation

/// `Play.type` and `PlayTypeSummary.type` (01 §3): ten offensive plays, then three defenses (schemas.py:315-345).
nonisolated enum PlayType: ServerEnum {
    /// `"pick_and_roll"`
    case pickAndRoll
    /// `"pick_and_pop"`
    case pickAndPop
    case isolation
    /// `"fast_break"`
    case fastBreak
    /// `"post_up"`
    case postUp
    case handoff
    /// `"off_ball_screen"`
    case offBallScreen
    /// `"spot_up"`
    case spotUp
    case cut
    case putback
    /// `"man_defense"`
    case manDefense
    /// `"zone_defense"`
    case zoneDefense
    case press
    case unknown(String)

    static let knownCases: [PlayType] = [.pickAndRoll, .pickAndPop, .isolation, .fastBreak, .postUp, .handoff, .offBallScreen, .spotUp, .cut, .putback, .manDefense, .zoneDefense, .press]

    var rawValue: String {
        switch self {
        case .pickAndRoll: "pick_and_roll"
        case .pickAndPop: "pick_and_pop"
        case .isolation: "isolation"
        case .fastBreak: "fast_break"
        case .postUp: "post_up"
        case .handoff: "handoff"
        case .offBallScreen: "off_ball_screen"
        case .spotUp: "spot_up"
        case .cut: "cut"
        case .putback: "putback"
        case .manDefense: "man_defense"
        case .zoneDefense: "zone_defense"
        case .press: "press"
        case .unknown(let rawValue): rawValue
        }
    }
}
