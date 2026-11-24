import Foundation

/// One team's box score (01 §4.9, 06 §3.10). `GameAnalysis.box_scores` has one per side, scouted first.
nonisolated struct TeamBoxScore: Codable, Hashable, Sendable, Identifiable {
    var side: TeamSide
    var teamName: String
    /// Every roster player sorted by jersey (also with zero stats), then unrostered jerseys with a stat.
    var players: [BoxScoreLine]
    /// Stats credited to the team but no identified player (`player.name` "Team").
    var teamUnattributed: BoxScoreLine
    /// Players plus the team line (`player.name` = team name).
    var totals: BoxScoreLine
    var possessions: Int
    /// 3 decimals; null with 0 possessions.
    var pointsPerPossession: Double?

    var id: String { side.rawValue }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case side
        case teamName = "team_name"
        case players
        case teamUnattributed = "team_unattributed"
        case totals
        case possessions
        case pointsPerPossession = "points_per_possession"
    }
}
