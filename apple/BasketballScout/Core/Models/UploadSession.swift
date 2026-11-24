import Foundation

/// A chunked film upload (01 §4.4, 04 §2.2): the answer of `POST /api/games/{id}/uploads`,
/// `GET /api/uploads/{id}`, `PUT /api/uploads/{id}/chunk?offset=N` and the `upload` sibling of two chunk 409s.
///
/// `received` is the only valid next `offset`; send `chunk_size` bytes per PUT (at most twice that).
/// Byte counts exceed 2^31, so they are `Int` (64-bit on every Apple platform).
nonisolated struct UploadSession: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var gameID: String
    /// The cleaned file name the server keeps (last path segment, control characters → spaces).
    var filename: String
    /// Announced total bytes.
    var size: Int
    /// Bytes stored so far: where the next chunk must start.
    var received: Int
    /// The server's preferred chunk length (default 16 MiB).
    var chunkSize: Int
    var status: UploadStatus
    /// Index of the live part this upload carries (docs/LIVE.md); nil for a whole film, and absent from
    /// servers older than live games.
    var liveSegment: Int?
    /// The live part's length in seconds.
    var liveDurationS: Double?
    var createdAt: Date?
    /// Bumped by every chunk; drives the server's one-hour abandonment rule.
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case gameID = "game_id"
        case filename
        case size
        case received
        case chunkSize = "chunk_size"
        case status
        case liveSegment = "live_segment"
        case liveDurationS = "live_duration_s"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated extension UploadSession {
    /// Every byte has arrived (the session stays `open` until `complete`).
    var isFullyReceived: Bool { received >= size }

    /// Bytes still to send.
    var remaining: Int { max(0, size - received) }

    /// `received / size` in 0...1.
    var fractionReceived: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }

    /// Length of the next chunk to send: `chunk_size`, or what is left (04 §2.8).
    var nextChunkLength: Int { min(chunkSize, remaining) }
}
