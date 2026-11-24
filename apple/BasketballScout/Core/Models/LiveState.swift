import Foundation

/// `LiveInfo.state` (docs/LIVE.md "Data"): `capturing` takes film, `finishing` takes no more film while the
/// parts already sent are analysed, `ended` is over. A game is live until it is `ended`.
nonisolated enum LiveState: ServerEnum {
    case capturing
    case finishing
    case ended
    case unknown(String)

    static let knownCases: [LiveState] = [.capturing, .finishing, .ended]

    var rawValue: String {
        switch self {
        case .capturing: "capturing"
        case .finishing: "finishing"
        case .ended: "ended"
        case .unknown(let rawValue): rawValue
        }
    }
}
