import Foundation

/// A recognised play (01 §4.9, 06 §3.8): an offensive action, or the defense a team played on a possession.
nonisolated struct Play: Codable, Hashable, Sendable, Identifiable {
    /// `pl_1`, `pl_2`, … in output order.
    var id: String
    var type: PlayType
    var category: PlayCategory
    /// Offense: the team running it. Defense: the team playing the defense.
    var side: TeamSide?
    /// Film seconds; `.nan` if the server sent null.
    var startT: Double
    var endT: Double
    var startFrame: Int
    var endFrame: Int
    var possessionID: Int?
    /// Role (`ball_handler`, `screener`, …; open set) → player. `{}` for defenses. A dictionary loses the
    /// server's role order: use `orderedPlayers`.
    var players: [String: PlayerRef]
    /// Defenses: how the possession ended.
    var outcome: PlayOutcome
    /// Offense: points scored (free throws included); defense: points allowed.
    var points: Int
    /// 0–1, 3 decimals; `.nan` if the server sent null.
    var confidence: Double
    /// Per-type details, keys kept as sent (`screen_side`, `roll_or_pop`, `zone_shape`, `also`, …).
    /// The web reads only `zone_shape`.
    var attrs: [String: JSONValue]
    /// Server sentence; may contain names.
    var description: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case type
        case category
        case side
        case startT = "start_t"
        case endT = "end_t"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case possessionID = "possession_id"
        case players
        case outcome
        case points
        case confidence
        case attrs
        case description
    }

    init(
        id: String,
        type: PlayType,
        category: PlayCategory,
        side: TeamSide?,
        startT: Double,
        endT: Double,
        startFrame: Int,
        endFrame: Int,
        possessionID: Int? = nil,
        players: [String: PlayerRef] = [:],
        outcome: PlayOutcome = .unknownOutcome,
        points: Int = 0,
        confidence: Double = 0.5,
        attrs: [String: JSONValue] = [:],
        description: String = ""
    ) {
        self.id = id
        self.type = type
        self.category = category
        self.side = side
        self.startT = startT
        self.endT = endT
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.possessionID = possessionID
        self.players = players
        self.outcome = outcome
        self.points = points
        self.confidence = confidence
        self.attrs = attrs
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(PlayType.self, forKey: .type)
        category = try container.decode(PlayCategory.self, forKey: .category)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        startT = try container.decodeLenientDouble(forKey: .startT)
        endT = try container.decodeLenientDouble(forKey: .endT)
        startFrame = try container.decode(Int.self, forKey: .startFrame)
        endFrame = try container.decode(Int.self, forKey: .endFrame)
        possessionID = try container.decodeIfPresent(Int.self, forKey: .possessionID)
        players = try container.decode([String: PlayerRef].self, forKey: .players)
        outcome = try container.decode(PlayOutcome.self, forKey: .outcome)
        points = try container.decode(Int.self, forKey: .points)
        confidence = try container.decodeLenientDouble(forKey: .confidence)
        attrs = try container.decode([String: JSONValue].self, forKey: .attrs)
        description = try container.decode(String.self, forKey: .description)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeLenientDouble(startT, forKey: .startT)
        try container.encodeLenientDouble(endT, forKey: .endT)
        try container.encode(startFrame, forKey: .startFrame)
        try container.encode(endFrame, forKey: .endFrame)
        try container.encodeIfPresent(possessionID, forKey: .possessionID)
        try container.encode(players, forKey: .players)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(points, forKey: .points)
        try container.encodeLenientDouble(confidence, forKey: .confidence)
        try container.encode(attrs, forKey: .attrs)
        try container.encode(description, forKey: .description)
    }
}

nonisolated extension Play {
    /// The role order the server writes for each play type (plays.py:795-1059; 06 §3.8).
    static func roleOrder(for type: PlayType) -> [String] {
        switch type {
        case .pickAndRoll, .pickAndPop: ["ball_handler", "screener"]
        case .handoff: ["ball_handler", "passer"]
        case .isolation: ["ball_handler", "defender"]
        case .postUp: ["post_player", "passer", "defender"]
        case .offBallScreen: ["screener", "receiver", "passer"]
        case .spotUp: ["shooter", "passer"]
        case .cut: ["cutter", "passer"]
        case .putback: ["shooter"]
        case .fastBreak: ["ball_handler", "shooter"]
        case .manDefense, .zoneDefense, .press, .unknown: []
        }
    }

    /// Fallback order for roles a play type does not list (the web's role table, labels.js:96-106).
    static let generalRoleOrder = [
        "ball_handler", "screener", "post_player", "cutter", "shooter", "passer", "receiver", "defender", "rebounder",
    ]

    /// `players` in the server's order: the type's roles first, then known roles, then others by name.
    var orderedPlayers: [(role: String, player: PlayerRef)] {
        let typeOrder = Self.roleOrder(for: type)
        func rank(_ role: String) -> (Int, Int, String) {
            if let index = typeOrder.firstIndex(of: role) { return (0, index, role) }
            if let index = Self.generalRoleOrder.firstIndex(of: role) { return (1, index, role) }
            return (2, 0, role)
        }
        return players.keys.sorted { rank($0) < rank($1) }.map { ($0, players[$0]!) }
    }

    /// `attrs.zone_shape` (`"2-3"`, `"1-3-1"`, `"matchup"`, `"unknown"`, …), the one attribute the web shows.
    var zoneShape: String? { attrs["zone_shape"]?.stringValue }
}
