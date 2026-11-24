import Foundation

/// Answer of `POST /api/games/{id}/live`, `GET /api/games/{id}/live` and `POST /api/games/{id}/live/finish`
/// (docs/LIVE.md "HTTP API"): the game with its `live` record, the parts on the server and the LIVE job.
nonisolated struct LiveStatus: Codable, Hashable, Sendable {
    var game: Game
    var segments: [LiveSegment]
    var job: Job?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case game
        case segments
        case job
    }
}

nonisolated extension LiveStatus {
    /// The index the next new part gets: one past the highest part the server has (0 when it has none).
    var nextSegmentIndex: Int { (segments.map(\.index).max() ?? -1) + 1 }
}
