import Foundation

/// A coach's manual fix for one track (01 §4.6, 05 §5.8): the answer of `PUT /api/games/{id}/tracks/{track_id}`
/// and an element of `TrackState.overrides`. Takes effect at the next REANALYZE; a full ANALYZE deletes all.
///
/// - player + side: the track is that roster player.
/// - no player + side: "Unknown player" of that team (keeps the side).
/// - `ignore`: not a player (referee, coach, fan); excluded from stats.
nonisolated struct TrackOverride: Codable, Hashable, Sendable, Identifiable {
    var trackID: Int
    /// Null = explicitly not a roster player.
    var playerID: String?
    var side: TeamSide?
    var ignore: Bool

    var id: Int { trackID }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case trackID = "track_id"
        case playerID = "player_id"
        case side
        case ignore
    }

    init(trackID: Int, playerID: String? = nil, side: TeamSide? = nil, ignore: Bool = false) {
        self.trackID = trackID
        self.playerID = playerID
        self.side = side
        self.ignore = ignore
    }
}
