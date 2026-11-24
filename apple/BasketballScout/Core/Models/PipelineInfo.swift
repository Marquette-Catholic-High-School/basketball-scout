import Foundation

/// Which pipeline produced the tracking (01 §4.9, 06 §3.3). The web shows `name`, `version` and `gpu`.
nonisolated struct PipelineInfo: Codable, Hashable, Sendable {
    /// `openhoopvision`, `builtin`, `synthetic` (demo) or other free text.
    var name: String
    /// `"0"` by default.
    var version: String
    /// Component → model description.
    var models: [String: String]
    var gpu: String?
    var elapsedS: Double?
    /// Arbitrary JSON, keys kept as sent (e.g. `analysis_fps`, `ohv_params`, demo `seed`).
    var options: [String: JSONValue]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case version
        case models
        case gpu
        case elapsedS = "elapsed_s"
        case options
    }
}
