import Foundation

/// Which team a roster, player, event or track belongs to (01 §3, 05 §1.1). There is no home/away.
/// `scouted` is the opponent being scouted; `other` is whoever they played in this film (often not us).
/// Also the `{side}` path segment and the `side` query value of the roster and export routes.
nonisolated enum TeamSide: ServerEnum {
    case scouted
    case other
    case unknown(String)

    static let knownCases: [TeamSide] = [.scouted, .other]

    var rawValue: String {
        switch self {
        case .scouted: "scouted"
        case .other: "other"
        case .unknown(let rawValue): rawValue
        }
    }
}
