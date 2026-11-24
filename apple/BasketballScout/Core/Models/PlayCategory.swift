import Foundation

/// `Play.category` and `PlayTypeSummary.category` (01 §3).
nonisolated enum PlayCategory: ServerEnum {
    case offense
    case defense
    case unknown(String)

    static let knownCases: [PlayCategory] = [.offense, .defense]

    var rawValue: String {
        switch self {
        case .offense: "offense"
        case .defense: "defense"
        case .unknown(let rawValue): rawValue
        }
    }
}
