import Foundation

/// One row of the event timeline (01 §4.9, 06 §3.6), in game order. `t` is the seek target in film seconds.
nonisolated struct TimelineEvent: Codable, Hashable, Sendable, Identifiable {
    /// Raw event id (`e00001` GPU, `ev_00001` demo), derived rows add `:ast`/`:blk`/`:stl`, possession rows
    /// are `poss<N>`. Unique.
    var id: String
    /// Film seconds; `.nan` if the server sent null.
    var t: Double
    /// Original film frame (sort tie-break).
    var frame: Int
    var type: EventType
    /// Short server text ("2PT Make", "Def. Rebound", "Possession: <team>").
    var label: String
    /// Team credited; for `possession_change` the team gaining the ball; null for period rows.
    var side: TeamSide?
    /// Primary actor (shooter, rebounder, passer, …).
    var player: PlayerRef?
    /// assist/block → the shooter, turnover → the stealer, steal → the player stolen from, foul → the fouled
    /// player, pass → the receiver, screen → the ball handler; otherwise null.
    var secondaryPlayer: PlayerRef?
    /// Team with the ball at this moment.
    var possessionSide: TeamSide?
    var possessionID: Int?
    /// 0/1/2/3.
    var points: Int
    /// Shots only.
    var isThree: Bool?
    /// Null for non-shot rows; `.unknownZone` for shots without a court position.
    var zone: ShotZone?
    /// e.g. `restricted_area`, `left_wing_3` (open set).
    var subzone: String?
    /// Shot location in full-court feet; null without a court mapping.
    var courtXY: XY?
    /// 0–1; `.nan` if the server sent null.
    var confidence: Double
    /// The offensive play covering this row.
    var playID: String?
    /// Raw GPU event id; groups a shot with its `:ast`/`:blk` rows; null for possession rows.
    var sourceEventID: String?
    /// Running score after this row.
    var scoreScouted: Int
    var scoreOther: Int
    /// Full server sentence; contains player names.
    var description: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case t
        case frame
        case type
        case label
        case side
        case player
        case secondaryPlayer = "secondary_player"
        case possessionSide = "possession_side"
        case possessionID = "possession_id"
        case points
        case isThree = "is_three"
        case zone
        case subzone
        case courtXY = "court_xy"
        case confidence
        case playID = "play_id"
        case sourceEventID = "source_event_id"
        case scoreScouted = "score_scouted"
        case scoreOther = "score_other"
        case description
    }

    init(
        id: String,
        t: Double,
        frame: Int,
        type: EventType,
        label: String,
        side: TeamSide? = nil,
        player: PlayerRef? = nil,
        secondaryPlayer: PlayerRef? = nil,
        possessionSide: TeamSide? = nil,
        possessionID: Int? = nil,
        points: Int = 0,
        isThree: Bool? = nil,
        zone: ShotZone? = nil,
        subzone: String? = nil,
        courtXY: XY? = nil,
        confidence: Double = 0.5,
        playID: String? = nil,
        sourceEventID: String? = nil,
        scoreScouted: Int = 0,
        scoreOther: Int = 0,
        description: String = ""
    ) {
        self.id = id
        self.t = t
        self.frame = frame
        self.type = type
        self.label = label
        self.side = side
        self.player = player
        self.secondaryPlayer = secondaryPlayer
        self.possessionSide = possessionSide
        self.possessionID = possessionID
        self.points = points
        self.isThree = isThree
        self.zone = zone
        self.subzone = subzone
        self.courtXY = courtXY
        self.confidence = confidence
        self.playID = playID
        self.sourceEventID = sourceEventID
        self.scoreScouted = scoreScouted
        self.scoreOther = scoreOther
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        t = try container.decodeLenientDouble(forKey: .t)
        frame = try container.decode(Int.self, forKey: .frame)
        type = try container.decode(EventType.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        player = try container.decodeIfPresent(PlayerRef.self, forKey: .player)
        secondaryPlayer = try container.decodeIfPresent(PlayerRef.self, forKey: .secondaryPlayer)
        possessionSide = try container.decodeIfPresent(TeamSide.self, forKey: .possessionSide)
        possessionID = try container.decodeIfPresent(Int.self, forKey: .possessionID)
        points = try container.decode(Int.self, forKey: .points)
        isThree = try container.decodeIfPresent(Bool.self, forKey: .isThree)
        zone = try container.decodeIfPresent(ShotZone.self, forKey: .zone)
        subzone = try container.decodeIfPresent(String.self, forKey: .subzone)
        courtXY = try container.decodeIfPresent(XY.self, forKey: .courtXY)
        confidence = try container.decodeLenientDouble(forKey: .confidence)
        playID = try container.decodeIfPresent(String.self, forKey: .playID)
        sourceEventID = try container.decodeIfPresent(String.self, forKey: .sourceEventID)
        scoreScouted = try container.decode(Int.self, forKey: .scoreScouted)
        scoreOther = try container.decode(Int.self, forKey: .scoreOther)
        description = try container.decode(String.self, forKey: .description)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeLenientDouble(t, forKey: .t)
        try container.encode(frame, forKey: .frame)
        try container.encode(type, forKey: .type)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeIfPresent(player, forKey: .player)
        try container.encodeIfPresent(secondaryPlayer, forKey: .secondaryPlayer)
        try container.encodeIfPresent(possessionSide, forKey: .possessionSide)
        try container.encodeIfPresent(possessionID, forKey: .possessionID)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(isThree, forKey: .isThree)
        try container.encodeIfPresent(zone, forKey: .zone)
        try container.encodeIfPresent(subzone, forKey: .subzone)
        try container.encodeIfPresent(courtXY, forKey: .courtXY)
        try container.encodeLenientDouble(confidence, forKey: .confidence)
        try container.encodeIfPresent(playID, forKey: .playID)
        try container.encodeIfPresent(sourceEventID, forKey: .sourceEventID)
        try container.encode(scoreScouted, forKey: .scoreScouted)
        try container.encode(scoreOther, forKey: .scoreOther)
        try container.encode(description, forKey: .description)
    }
}
