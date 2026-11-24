import Foundation

/// One button of the "Which team is …?" banner (03 §7.6, 06 §5.3; game.js:300-356): the analysis team the
/// coach says is the scouted one, with the web's label and colour swatch.
nonisolated struct GameDetailTeamChoice: Identifiable, Hashable, Sendable {
    /// The pipeline team id the coach picks as the scouted team.
    let teamID: Int
    /// The other team's id; it becomes the other side.
    let otherTeamID: Int
    /// The side the analysis gave this team.
    let side: TeamSide
    /// "Navy jerseys", "Dark jerseys (lighter)", "White jerseys (team 2)" (`TeamSummary.teamChoiceLabels`).
    let label: String
    /// The jersey colour; #888888 when it is unknown.
    let swatch: HexColor

    var id: Int { teamID }

    /// The PATCH body: `{"team_id_map": {"<chosen>": "scouted", "<other>": "other"}}` (03 §7.6).
    var update: GameUpdate { .confirmTeams(scoutedTeamID: teamID, otherTeamID: otherTeamID) }

    /// The analysis already counts this team as the scouted one: confirming needs no re-run ("Thanks - teams
    /// confirmed."). Otherwise a re-analysis applies the choice (game.js:341-349).
    var keepsCurrentSides: Bool { side == .scouted }

    /// The banner's buttons in the analysis's team order; empty unless the banner is due: exactly two teams with
    /// a team id and a colour, and the coach has not chosen yet (`GameAnalysis.needsTeamConfirmation(for:)`).
    static func choices(for analysis: GameAnalysis, game: Game) -> [GameDetailTeamChoice] {
        guard analysis.needsTeamConfirmation(for: game) else { return [] }
        let teams = analysis.confirmableTeams
        guard teams.count == 2, let first = teams[0].teamID, let second = teams[1].teamID, first != second else { return [] }
        let labels = TeamSummary.teamChoiceLabels(for: teams) { detectedColor($0).resolved?.relativeLuminance }
        return [
            GameDetailTeamChoice(
                teamID: first, otherTeamID: second, side: teams[0].side, label: labels[0], swatch: swatch(for: teams[0])),
            GameDetailTeamChoice(
                teamID: second, otherTeamID: first, side: teams[1].side, label: labels[1], swatch: swatch(for: teams[1])),
        ]
    }

    /// The swatch of a team: its detected colour (`color_rgb`, else `color_name`), else #888888 (06 §5.3).
    static func swatch(for team: TeamSummary) -> HexColor {
        TeamPalette.swatch(for: detectedColor(team))
    }

    private static func detectedColor(_ team: TeamSummary) -> DetectedTeamColor {
        DetectedTeamColor(rgb: team.colorRGB.map { [$0.red, $0.green, $0.blue] }, name: team.colorName)
    }
}
