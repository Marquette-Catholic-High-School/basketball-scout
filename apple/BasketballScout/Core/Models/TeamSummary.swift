import Foundation

/// One team as the analysis sees it (01 §4.9, 06 §3.4). `GameAnalysis.teams` is always `[scouted, other]`.
nonisolated struct TeamSummary: Codable, Hashable, Sendable, Identifiable {
    var side: TeamSide
    /// Roster team name, else the game's team name, else "Scouted team"/"Other team"; never empty.
    var name: String
    /// The pipeline's team id (jersey-colour cluster) mapped to this side.
    var teamID: Int?
    /// Detected jersey colour; often null for real GPU runs.
    var colorRGB: RGB?
    /// `dark`/`light` from the GPU, colour words (`navy`) from the demo generator.
    var colorName: String?
    /// Final points.
    var score: Int

    var id: String { side.rawValue }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case side
        case name
        case teamID = "team_id"
        case colorRGB = "color_rgb"
        case colorName = "color_name"
        case score
    }
}
