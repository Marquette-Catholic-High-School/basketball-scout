import Foundation

/// One person the GPU tracker followed and who the last analysis decided it was (01 §4.6, 05 §5.7,
/// 06 §3.12): `GameAnalysis.track_assignments` and `TrackState.assignments`.
///
/// Display `side`, never `team_id` (a jersey-colour cluster). A full ANALYZE renumbers every track; compare
/// `stalenessKey` before sending overrides (09 D1 #6).
nonisolated struct TrackAssignment: Codable, Hashable, Sendable, Identifiable {
    /// The pipeline's track id (0 … 2^63-1), unique within one GPU run.
    var trackID: Int
    /// Pipeline team cluster (usually 0/1), not a side.
    var teamID: Int?
    /// Null for referees and unmapped tracks.
    var side: TeamSide?
    /// `player`, `referee` or `unknown` (a plain string on the server; 05 §9.18).
    var role: String
    /// `RosterPlayer.id` matched at the last analysis; may name a player removed since.
    var playerID: String?
    /// Roster jersey when matched, else the best read, unless that read is a roster number on its side.
    var jersey: String?
    /// Strongest normalised OCR read; null when there was no usable read.
    var bestRead: String?
    /// Read (a jersey string: `"0"` ≠ `"00"`) → summed OCR confidence (can be > 1). Order is lost in a
    /// dictionary: use `rankedVotes`. A null weight (NaN) decodes as `.nan`.
    var votes: [String: Double]
    /// 0–1; `.nan` if the server sent null.
    var matchScore: Double
    var method: TrackMethod
    /// Analysed samples this track appears in (presence), not video frames.
    var frames: Int
    /// Excluded by an `ignore` override.
    var ignored: Bool

    var id: Int { trackID }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case trackID = "track_id"
        case teamID = "team_id"
        case side
        case role
        case playerID = "player_id"
        case jersey
        case bestRead = "best_read"
        case votes
        case matchScore = "match_score"
        case method
        case frames
        case ignored
    }

    init(
        trackID: Int,
        teamID: Int? = nil,
        side: TeamSide? = nil,
        role: String = "player",
        playerID: String? = nil,
        jersey: String? = nil,
        bestRead: String? = nil,
        votes: [String: Double] = [:],
        matchScore: Double = 0,
        method: TrackMethod = .noReads,
        frames: Int = 0,
        ignored: Bool = false
    ) {
        self.trackID = trackID
        self.teamID = teamID
        self.side = side
        self.role = role
        self.playerID = playerID
        self.jersey = jersey
        self.bestRead = bestRead
        self.votes = votes
        self.matchScore = matchScore
        self.method = method
        self.frames = frames
        self.ignored = ignored
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(Int.self, forKey: .trackID)
        teamID = try container.decodeIfPresent(Int.self, forKey: .teamID)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        role = try container.decode(String.self, forKey: .role)
        playerID = try container.decodeIfPresent(String.self, forKey: .playerID)
        jersey = try container.decodeIfPresent(String.self, forKey: .jersey)
        bestRead = try container.decodeIfPresent(String.self, forKey: .bestRead)
        votes = try container.decodeLenientDoubleDictionary(forKey: .votes)
        matchScore = try container.decodeLenientDouble(forKey: .matchScore)
        method = try container.decode(TrackMethod.self, forKey: .method)
        frames = try container.decode(Int.self, forKey: .frames)
        ignored = try container.decode(Bool.self, forKey: .ignored)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackID, forKey: .trackID)
        try container.encodeIfPresent(teamID, forKey: .teamID)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(playerID, forKey: .playerID)
        try container.encodeIfPresent(jersey, forKey: .jersey)
        try container.encodeIfPresent(bestRead, forKey: .bestRead)
        try container.encodeLenientDoubleDictionary(votes, forKey: .votes)
        try container.encodeLenientDouble(matchScore, forKey: .matchScore)
        try container.encode(method, forKey: .method)
        try container.encode(frames, forKey: .frames)
        try container.encode(ignored, forKey: .ignored)
    }
}
