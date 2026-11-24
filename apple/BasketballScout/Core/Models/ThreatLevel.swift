import Foundation

/// `KeyPlayer.threat_level` (01 §4.7).
nonisolated enum ThreatLevel: ServerEnum {
    case high
    case medium
    case low
    case unknown(String)

    static let knownCases: [ThreatLevel] = [.high, .medium, .low]

    var rawValue: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .unknown(let rawValue): rawValue
        }
    }
}
