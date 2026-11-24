import Foundation

/// `zone` of shots and shot rows (01 §3, 06 §3.14). The server's own `unknown` value (a shot with no court
/// location) is `.unknownZone`; `.unknown(raw)` is a value this app does not know.
nonisolated enum ShotZone: ServerEnum {
    case paint
    case mid
    case three
    /// `"unknown"`
    case unknownZone
    case unknown(String)

    static let knownCases: [ShotZone] = [.paint, .mid, .three, .unknownZone]

    var rawValue: String {
        switch self {
        case .paint: "paint"
        case .mid: "mid"
        case .three: "three"
        case .unknownZone: "unknown"
        case .unknown(let rawValue): rawValue
        }
    }
}
