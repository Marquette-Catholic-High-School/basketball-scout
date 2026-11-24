import Foundation

/// `Job.status` (01 §3). `queued` and `running` are active; the others are final.
nonisolated enum JobStatus: ServerEnum {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case unknown(String)

    static let knownCases: [JobStatus] = [.queued, .running, .succeeded, .failed, .cancelled]

    var rawValue: String {
        switch self {
        case .queued: "queued"
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unknown(let rawValue): rawValue
        }
    }
}
