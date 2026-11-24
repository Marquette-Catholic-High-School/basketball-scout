import Foundation

/// Body of `PUT /api/games/{id}/tracks/{track_id}` → 200 `TrackOverride` (01 §4.6, 05 §4.10).
///
/// The track id in the URL wins; `track_id` in the body is ignored (sent when given, as the web does).
/// `player_id` must be on the `side` roster (either roster when `side` is null), else 422 — send `side`
/// with a player choice. `player_id`, `side` and `ignore` are always sent (null when not set). 409 while a
/// full ANALYZE is queued or running.
nonisolated struct TrackOverrideBody: Codable, Hashable, Sendable {
    var trackID: Int?
    var playerID: String?
    var side: TeamSide?
    var ignore: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case trackID = "track_id"
        case playerID = "player_id"
        case side
        case ignore
    }

    init(trackID: Int? = nil, playerID: String? = nil, side: TeamSide? = nil, ignore: Bool = false) {
        self.trackID = trackID
        self.playerID = playerID
        self.side = side
        self.ignore = ignore
    }

    /// Assign the track to a roster player of `side`.
    static func assign(trackID: Int, playerID: String, side: TeamSide) -> TrackOverrideBody {
        TrackOverrideBody(trackID: trackID, playerID: playerID, side: side, ignore: false)
    }

    /// "Unknown player" of `side` (nil keeps the track's team; 05 §7.6).
    static func unknownPlayer(trackID: Int, side: TeamSide?) -> TrackOverrideBody {
        TrackOverrideBody(trackID: trackID, playerID: nil, side: side, ignore: false)
    }

    /// "Not a player (referee, coach, fan…)".
    static func notAPlayer(trackID: Int, side: TeamSide?) -> TrackOverrideBody {
        TrackOverrideBody(trackID: trackID, playerID: nil, side: side, ignore: true)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decodeIfPresent(Int.self, forKey: .trackID)
        playerID = try container.decodeIfPresent(String.self, forKey: .playerID)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        ignore = try container.decodeIfPresent(Bool.self, forKey: .ignore) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(trackID, forKey: .trackID)
        try container.encode(playerID, forKey: .playerID)
        try container.encode(side, forKey: .side)
        try container.encode(ignore, forKey: .ignore)
    }
}
