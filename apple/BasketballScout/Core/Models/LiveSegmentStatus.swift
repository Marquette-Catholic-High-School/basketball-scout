import Foundation

/// `LiveSegment.status` (docs/LIVE.md "Data"): `uploaded` waits for a GPU, `processing` is on one, `done`
/// has its stats in the analysis, `failed` could not be analysed (its stretch of film has no stats), `empty`
/// had no game play in it (a timeout, halftime, warm-ups): settled like `done`, without stats, not an error.
nonisolated enum LiveSegmentStatus: ServerEnum {
    case uploaded
    case processing
    case done
    case failed
    case empty
    case unknown(String)

    static let knownCases: [LiveSegmentStatus] = [.uploaded, .processing, .done, .failed, .empty]

    var rawValue: String {
        switch self {
        case .uploaded: "uploaded"
        case .processing: "processing"
        case .done: "done"
        case .failed: "failed"
        case .empty: "empty"
        case .unknown(let rawValue): rawValue
        }
    }
}
