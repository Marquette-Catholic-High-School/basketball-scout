import Foundation

/// `LiveInfo.end_reason` (docs/LIVE.md "Data"): why a live game stopped taking film. `finished` = ended by
/// the coach, `idle` = no film arrived for a long time, `limit` = the longest film the server takes,
/// `cancelled` / `failed` = its job was cancelled or failed, `empty` = ended before any film arrived.
nonisolated enum LiveEndReason: ServerEnum {
    case finished
    case idle
    case limit
    case cancelled
    case failed
    case empty
    case unknown(String)

    static let knownCases: [LiveEndReason] = [.finished, .idle, .limit, .cancelled, .failed, .empty]

    var rawValue: String {
        switch self {
        case .finished: "finished"
        case .idle: "idle"
        case .limit: "limit"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .empty: "empty"
        case .unknown(let rawValue): rawValue
        }
    }
}
