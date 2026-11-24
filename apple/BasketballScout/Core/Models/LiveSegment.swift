import Foundation

/// One part of a live game's film (docs/LIVE.md "Data"; the elements of `LiveStatus.segments`).
nonisolated struct LiveSegment: Codable, Hashable, Sendable, Identifiable {
    var gameID: String
    /// Position in the stream, from 0.
    var index: Int
    var durationS: Double
    /// Bytes.
    var size: Int
    var filename: String
    var status: LiveSegmentStatus
    /// GPU calls so far.
    var attempts: Int
    var processor: String?
    /// Processor handle of its GPU call.
    var externalID: String?
    /// 0–100 on the GPU.
    var progress: Double?
    /// Set when `status == .failed`.
    var error: ErrorInfo?
    var uploadedAt: Date?
    var submittedAt: Date?
    var finishedAt: Date?

    var id: Int { index }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case gameID = "game_id"
        case index
        case durationS = "duration_s"
        case size
        case filename
        case status
        case attempts
        case processor
        case externalID = "external_id"
        case progress
        case error
        case uploadedAt = "uploaded_at"
        case submittedAt = "submitted_at"
        case finishedAt = "finished_at"
    }
}
