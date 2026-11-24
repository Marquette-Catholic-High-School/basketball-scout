import Foundation

/// `TrackAssignment.method` (01 §3, 05 §5.7): how the strongest jersey evidence matched. The server's `none`
/// (no usable read) is `.noReads`, because `.none` would clash with `Optional.none`.
nonisolated enum TrackMethod: ServerEnum {
    case exact
    case fuzzy
    case partial
    case manual
    case unrostered
    /// `"none"`
    case noReads
    case unknown(String)

    static let knownCases: [TrackMethod] = [.exact, .fuzzy, .partial, .manual, .unrostered, .noReads]

    var rawValue: String {
        switch self {
        case .exact: "exact"
        case .fuzzy: "fuzzy"
        case .partial: "partial"
        case .manual: "manual"
        case .unrostered: "unrostered"
        case .noReads: "none"
        case .unknown(let rawValue): rawValue
        }
    }
}
