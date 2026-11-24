import Foundation

/// Body of `PATCH /api/games/{id}` → 200 `Game` (01 §4.2, 03 §1.5, §2.1). Only keys that are present change
/// anything, so every field is a `Patch`: `.unset` leaves it out, `.null` sends null, `.value` sends it.
///
/// What `.null` does per field (the server's rules; 09 D1 #3, R26 forbid sending some nulls):
/// - `scoutedTeam`: the server refuses null (422 "The scouted team needs a name"), so encoding `.null` throws.
/// - `otherTeam`: sent as `""` (what the server stores for null; never send null).
/// - `title`: null is stored as `""`.
/// - `gameDate`, `location`, `level`, `notes`, `scoutedColor`: cleared.
/// - `teamIDMap`: null resets it to `{}` (automatic).
///
/// `{}` is a valid no-op that bumps `updated_at`. Status, flags and film fields cannot be patched.
/// A changed `team_id_map` or `scouted_color` only takes effect at the next (re)analysis.
nonisolated struct GameUpdate: Codable, Hashable, Sendable {
    var scoutedTeam: Patch<String>
    var otherTeam: Patch<String>
    var title: Patch<String>
    var gameDate: Patch<GameDate>
    var location: Patch<String>
    var level: Patch<String>
    var notes: Patch<String>
    var scoutedColor: Patch<String>
    /// Pipeline team id (as a string) → side, e.g. `["0": .scouted, "1": .other]`.
    var teamIDMap: Patch<[String: TeamSide]>

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scoutedTeam = "scouted_team"
        case otherTeam = "other_team"
        case title
        case gameDate = "game_date"
        case location
        case level
        case notes
        case scoutedColor = "scouted_color"
        case teamIDMap = "team_id_map"
    }

    init(
        scoutedTeam: Patch<String> = .unset,
        otherTeam: Patch<String> = .unset,
        title: Patch<String> = .unset,
        gameDate: Patch<GameDate> = .unset,
        location: Patch<String> = .unset,
        level: Patch<String> = .unset,
        notes: Patch<String> = .unset,
        scoutedColor: Patch<String> = .unset,
        teamIDMap: Patch<[String: TeamSide]> = .unset
    ) {
        self.scoutedTeam = scoutedTeam
        self.otherTeam = otherTeam
        self.title = title
        self.gameDate = gameDate
        self.location = location
        self.level = level
        self.notes = notes
        self.scoutedColor = scoutedColor
        self.teamIDMap = teamIDMap
    }

    /// The team-confirmation PATCH (03 §7.6, 06 §5.3): the chosen pipeline team is the scouted one,
    /// the other team the other side: `{"team_id_map": {"<chosen>": "scouted", "<other>": "other"}}`.
    /// It does not re-run the analysis; start a `reanalyze` afterwards unless the chosen team was already
    /// the scouted side.
    static func confirmTeams(scoutedTeamID: Int, otherTeamID: Int) -> GameUpdate {
        GameUpdate(teamIDMap: .value([String(scoutedTeamID): .scouted, String(otherTeamID): .other]))
    }

    /// No field is set: the body is `{}`.
    var isEmpty: Bool {
        scoutedTeam.isUnset && otherTeam.isUnset && title.isUnset && gameDate.isUnset && location.isUnset
            && level.isUnset && notes.isUnset && scoutedColor.isUnset && teamIDMap.isUnset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scoutedTeam = try container.decode(Patch<String>.self, forKey: .scoutedTeam)
        otherTeam = try container.decode(Patch<String>.self, forKey: .otherTeam)
        title = try container.decode(Patch<String>.self, forKey: .title)
        gameDate = try container.decode(Patch<GameDate>.self, forKey: .gameDate)
        location = try container.decode(Patch<String>.self, forKey: .location)
        level = try container.decode(Patch<String>.self, forKey: .level)
        notes = try container.decode(Patch<String>.self, forKey: .notes)
        scoutedColor = try container.decode(Patch<String>.self, forKey: .scoutedColor)
        teamIDMap = try container.decode(Patch<[String: TeamSide]>.self, forKey: .teamIDMap)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if scoutedTeam.isNull {
            throw EncodingError.invalidValue(scoutedTeam, EncodingError.Context(
                codingPath: container.codingPath + [CodingKeys.scoutedTeam],
                debugDescription: "scouted_team cannot be null: the server answers 422 (09 R26). Leave it .unset."))
        }
        try container.encode(scoutedTeam, forKey: .scoutedTeam)
        try container.encode(otherTeam.isNull ? .value("") : otherTeam, forKey: .otherTeam)
        try container.encode(title, forKey: .title)
        try container.encode(gameDate, forKey: .gameDate)
        try container.encode(location, forKey: .location)
        try container.encode(level, forKey: .level)
        try container.encode(notes, forKey: .notes)
        try container.encode(scoutedColor, forKey: .scoutedColor)
        try container.encode(teamIDMap, forKey: .teamIDMap)
    }
}
