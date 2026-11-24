import Foundation

/// Body of `PUT /api/games/{id}/rosters/{side}` → 200 `Roster` (01 §4.5, 05 §4.3): replaces the whole list.
///
/// - `team_name` (≤ 120): nil sends null, which keeps the current name; `""` stores an empty name. The web
///   always sends the (trimmed) field value.
/// - `players` (≤ 200, required): ids must be unique within the list (422 otherwise); players without an id
///   get new ones. Order is stored as sent. Duplicate jerseys are accepted by the server: refuse them first.
/// Any roster write drops track overrides whose player left the roster (05 §6.6).
nonisolated struct RosterReplace: Codable, Hashable, Sendable {
    var teamName: String?
    var players: [RosterPlayerInput]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case teamName = "team_name"
        case players
    }

    /// The server's limit on `players`.
    static let maximumPlayers = 200

    init(teamName: String?, players: [RosterPlayerInput]) {
        self.teamName = teamName
        self.players = players
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName)
        players = try container.decode([RosterPlayerInput].self, forKey: .players)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(teamName, forKey: .teamName)
        try container.encode(players, forKey: .players)
    }
}
