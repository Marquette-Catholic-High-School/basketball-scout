import Foundation

/// One field-goal attempt (01 §4.9, 06 §3.9); free throws are not shots. Draw shot charts from `halfCourtXY`.
nonisolated struct ShotRecord: Codable, Hashable, Sendable, Identifiable {
    /// The shot's timeline row id.
    var eventID: String
    /// Film seconds; `.nan` if the server sent null.
    var t: Double
    /// Shooter's team.
    var side: TeamSide?
    var player: PlayerRef?
    /// A blocked shot is a miss.
    var made: Bool
    /// 0/2/3.
    var points: Int
    var isThree: Bool?
    /// Never null; `.unknownZone` without a court location.
    var zone: ShotZone
    var subzone: String?
    /// Full-court feet.
    var courtXY: XY?
    /// Normalised half court: x = feet from the attacked baseline, y = feet from the offense's left sideline.
    var halfCourtXY: XY?
    var assisted: Bool
    var blocked: Bool
    var playID: String?

    var id: String { eventID }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventID = "event_id"
        case t
        case side
        case player
        case made
        case points
        case isThree = "is_three"
        case zone
        case subzone
        case courtXY = "court_xy"
        case halfCourtXY = "half_court_xy"
        case assisted
        case blocked
        case playID = "play_id"
    }

    init(
        eventID: String,
        t: Double,
        side: TeamSide?,
        player: PlayerRef? = nil,
        made: Bool,
        points: Int,
        isThree: Bool? = nil,
        zone: ShotZone = .unknownZone,
        subzone: String? = nil,
        courtXY: XY? = nil,
        halfCourtXY: XY? = nil,
        assisted: Bool = false,
        blocked: Bool = false,
        playID: String? = nil
    ) {
        self.eventID = eventID
        self.t = t
        self.side = side
        self.player = player
        self.made = made
        self.points = points
        self.isThree = isThree
        self.zone = zone
        self.subzone = subzone
        self.courtXY = courtXY
        self.halfCourtXY = halfCourtXY
        self.assisted = assisted
        self.blocked = blocked
        self.playID = playID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        t = try container.decodeLenientDouble(forKey: .t)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        player = try container.decodeIfPresent(PlayerRef.self, forKey: .player)
        made = try container.decode(Bool.self, forKey: .made)
        points = try container.decode(Int.self, forKey: .points)
        isThree = try container.decodeIfPresent(Bool.self, forKey: .isThree)
        zone = try container.decode(ShotZone.self, forKey: .zone)
        subzone = try container.decodeIfPresent(String.self, forKey: .subzone)
        courtXY = try container.decodeIfPresent(XY.self, forKey: .courtXY)
        halfCourtXY = try container.decodeIfPresent(XY.self, forKey: .halfCourtXY)
        assisted = try container.decode(Bool.self, forKey: .assisted)
        blocked = try container.decode(Bool.self, forKey: .blocked)
        playID = try container.decodeIfPresent(String.self, forKey: .playID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encodeLenientDouble(t, forKey: .t)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeIfPresent(player, forKey: .player)
        try container.encode(made, forKey: .made)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(isThree, forKey: .isThree)
        try container.encode(zone, forKey: .zone)
        try container.encodeIfPresent(subzone, forKey: .subzone)
        try container.encodeIfPresent(courtXY, forKey: .courtXY)
        try container.encodeIfPresent(halfCourtXY, forKey: .halfCourtXY)
        try container.encode(assisted, forKey: .assisted)
        try container.encode(blocked, forKey: .blocked)
        try container.encodeIfPresent(playID, forKey: .playID)
    }
}
