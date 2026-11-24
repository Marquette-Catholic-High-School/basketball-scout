import Foundation

/// The original film as the analysis saw it (01 §4.9, 06 §3.2). `fps`, `duration_s` and `analysis_fps` are
/// bounded on the server (> 0 / ≥ 0), so they can never be NaN.
nonisolated struct VideoInfo: Codable, Hashable, Sendable {
    /// `""` by default.
    var filename: String
    var fps: Double
    /// Original film pixels.
    var width: Int
    var height: Int
    var frameCount: Int
    var durationS: Double
    /// The rate tracks were sampled at.
    var analysisFPS: Double
    /// E.g. `h264`.
    var codec: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case filename
        case fps
        case width
        case height
        case frameCount = "frame_count"
        case durationS = "duration_s"
        case analysisFPS = "analysis_fps"
        case codec
    }
}
