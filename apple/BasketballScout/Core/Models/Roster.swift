import Foundation

/// One team's roster for a game (01 §4.5, 05 §5.1): `GET/PUT /api/games/{id}/rosters/{side}`, the player
/// routes (POST, PATCH and DELETE all return the whole roster, 200) and `GameRosters`.
///
/// Before the first save `team_name` is the game's name for that side and `updated_at` is null. No version
/// or ETag exists: the last writer wins, so serialise writes per side and refetch on appear (09 R37).
nonisolated struct Roster: Codable, Hashable, Sendable {
    var gameID: String
    var side: TeamSide
    /// May be `""`.
    var teamName: String
    /// In saved order (PUT order, import order, POST appends).
    var players: [RosterPlayer]
    /// Null until the first save.
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case gameID = "game_id"
        case side
        case teamName = "team_name"
        case players
        case updatedAt = "updated_at"
    }

    init(gameID: String, side: TeamSide, teamName: String = "", players: [RosterPlayer] = [], updatedAt: Date? = nil) {
        self.gameID = gameID
        self.side = side
        self.teamName = teamName
        self.players = players
        self.updatedAt = updatedAt
    }

    /// The player with `id`, if on this roster.
    func player(id: String) -> RosterPlayer? {
        players.first { $0.id == id }
    }

    /// Never saved: `updated_at` is null.
    var isNeverSaved: Bool { updatedAt == nil }
}
