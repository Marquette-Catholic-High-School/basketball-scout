import Foundation

/// `Job.stage` (01 §3, 03 §3.2). ANALYZE goes through every stage; REANALYZE: queued → analyzing →
/// (reporting) → done; REPORT: queued → reporting → done. A failed job keeps the stage it failed at
/// (except a job the queue refused, which has `done`, 09 B4).
nonisolated enum JobStage: ServerEnum {
    case queued
    case preparing
    /// `"uploading_to_gpu"`
    case uploadingToGPU
    /// `"gpu_processing"`
    case gpuProcessing
    /// `"downloading_results"`
    case downloadingResults
    case analyzing
    case reporting
    case done
    case unknown(String)

    static let knownCases: [JobStage] = [.queued, .preparing, .uploadingToGPU, .gpuProcessing, .downloadingResults, .analyzing, .reporting, .done]

    var rawValue: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .uploadingToGPU: "uploading_to_gpu"
        case .gpuProcessing: "gpu_processing"
        case .downloadingResults: "downloading_results"
        case .analyzing: "analyzing"
        case .reporting: "reporting"
        case .done: "done"
        case .unknown(let rawValue): rawValue
        }
    }
}
