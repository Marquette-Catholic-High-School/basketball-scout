import Foundation

/// One possession (01 §4.9, 06 §3.7), numbered 1… in game order. The web shows possessions only as the
/// marker-strip band, the timeline's possession chip and per-team counts.
nonisolated struct Possession: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    /// The team with the ball (null in theory only).
    var side: TeamSide?
    /// Film seconds; `.nan` if the server sent null.
    var startT: Double
    var endT: Double
    var startFrame: Int
    var endFrame: Int
    var outcome: PossessionOutcome
    /// Points scored by `side` during it (and-one free throws included).
    var points: Int
    /// `def_rebound`, `steal`, `turnover`, `made_basket`, `jump_ball`, `period_start`, `inferred` (open set).
    var startReason: String
    var transition: Bool
    /// Timeline row ids it owns; the first is its `poss<N>` row.
    var eventIDs: [String]
    /// Offense and defense plays in it.
    var playIDs: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case side
        case startT = "start_t"
        case endT = "end_t"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case outcome
        case points
        case startReason = "start_reason"
        case transition
        case eventIDs = "event_ids"
        case playIDs = "play_ids"
    }

    init(
        id: Int,
        side: TeamSide?,
        startT: Double,
        endT: Double,
        startFrame: Int,
        endFrame: Int,
        outcome: PossessionOutcome = .unknownOutcome,
        points: Int = 0,
        startReason: String = "",
        transition: Bool = false,
        eventIDs: [String] = [],
        playIDs: [String] = []
    ) {
        self.id = id
        self.side = side
        self.startT = startT
        self.endT = endT
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.outcome = outcome
        self.points = points
        self.startReason = startReason
        self.transition = transition
        self.eventIDs = eventIDs
        self.playIDs = playIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        startT = try container.decodeLenientDouble(forKey: .startT)
        endT = try container.decodeLenientDouble(forKey: .endT)
        startFrame = try container.decode(Int.self, forKey: .startFrame)
        endFrame = try container.decode(Int.self, forKey: .endFrame)
        outcome = try container.decode(PossessionOutcome.self, forKey: .outcome)
        points = try container.decode(Int.self, forKey: .points)
        startReason = try container.decode(String.self, forKey: .startReason)
        transition = try container.decode(Bool.self, forKey: .transition)
        eventIDs = try container.decode([String].self, forKey: .eventIDs)
        playIDs = try container.decode([String].self, forKey: .playIDs)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeLenientDouble(startT, forKey: .startT)
        try container.encodeLenientDouble(endT, forKey: .endT)
        try container.encode(startFrame, forKey: .startFrame)
        try container.encode(endFrame, forKey: .endFrame)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(points, forKey: .points)
        try container.encode(startReason, forKey: .startReason)
        try container.encode(transition, forKey: .transition)
        try container.encode(eventIDs, forKey: .eventIDs)
        try container.encode(playIDs, forKey: .playIDs)
    }
}
