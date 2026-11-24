import Foundation

/// Optional body of `POST /api/games/{id}/live` (docs/LIVE.md "HTTP API"): the part length the client will
/// send (20 to 600 seconds). Without a body the server picks it; read it from `LiveInfo.segmentSeconds`.
nonisolated struct LiveStart: Codable, Hashable, Sendable {
    var segmentSeconds: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case segmentSeconds = "segment_seconds"
    }

    init(segmentSeconds: Int? = nil) {
        self.segmentSeconds = segmentSeconds
    }
}
