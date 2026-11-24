import Foundation

/// `Game.status` (01 §3, 03 §3.7). It follows ANALYZE/REANALYZE jobs only; report jobs never change it.
nonisolated enum GameStatus: ServerEnum {
    case draft
    case uploaded
    case queued
    case processing
    case ready
    case failed
    case unknown(String)

    static let knownCases: [GameStatus] = [.draft, .uploaded, .queued, .processing, .ready, .failed]

    var rawValue: String {
        switch self {
        case .draft: "draft"
        case .uploaded: "uploaded"
        case .queued: "queued"
        case .processing: "processing"
        case .ready: "ready"
        case .failed: "failed"
        case .unknown(let rawValue): rawValue
        }
    }
}
