import Foundation

/// A player as the analysis names one (01 §4.9, 06 §3.5), embedded in timeline rows, shots, plays and box
/// score lines. In a box score the team line has `name` "Team" and the totals line the team name.
nonisolated struct PlayerRef: Codable, Hashable, Sendable {
    /// `RosterPlayer.id` when matched.
    var playerID: String?
    /// As typed (`"0"` ≠ `"00"`).
    var jersey: String?
    /// Roster "First Last" (a minor's name).
    var name: String?
    var side: TeamSide?
    /// 0–1; `.nan` if the server sent null.
    var matchConfidence: Double
    /// Server-computed: "#23 Name", "#23", the name, or "Unknown player".
    var label: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case playerID = "player_id"
        case jersey
        case name
        case side
        case matchConfidence = "match_confidence"
        case label
    }

    init(playerID: String? = nil, jersey: String? = nil, name: String? = nil, side: TeamSide? = nil, matchConfidence: Double = 0, label: String? = nil) {
        self.playerID = playerID
        self.jersey = jersey
        self.name = name
        self.side = side
        self.matchConfidence = matchConfidence
        self.label = label ?? Self.label(jersey: jersey, name: name)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playerID = try container.decodeIfPresent(String.self, forKey: .playerID)
        jersey = try container.decodeIfPresent(String.self, forKey: .jersey)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side)
        matchConfidence = try container.decodeLenientDouble(forKey: .matchConfidence)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? Self.label(jersey: jersey, name: name)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(playerID, forKey: .playerID)
        try container.encodeIfPresent(jersey, forKey: .jersey)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeLenientDouble(matchConfidence, forKey: .matchConfidence)
        try container.encode(label, forKey: .label)
    }

    /// The server's `label` rule (schemas.py:235-242).
    static func label(jersey: String?, name: String?) -> String {
        let jersey = jersey ?? ""
        let name = name ?? ""
        if !jersey.isEmpty, !name.isEmpty { return "#\(jersey) \(name)" }
        if !jersey.isEmpty { return "#\(jersey)" }
        return name.isEmpty ? "Unknown player" : name
    }
}
