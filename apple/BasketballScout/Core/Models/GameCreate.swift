import Foundation

/// Body of `POST /api/games` → 201 `Game` (01 §4.2, 03 §1.5).
///
/// Limits (code points, 01 §1.4): `scouted_team` 1–120 (required), `other_team` ≤ 120, `title` ≤ 200,
/// `location` ≤ 200, `level` ≤ 40, `notes` ≤ 5000, `scouted_color` ≤ 40. The server does not trim and
/// refuses `other_team: null`; this encoder always sends `other_team` as a string and every optional field
/// (null when empty), as the web's form does. Use `normalized()` to apply the form's trimming first.
nonisolated struct GameCreate: Codable, Hashable, Sendable {
    var scoutedTeam: String
    /// Never null on the wire: `""` when there is no opponent name (09 D1 #3).
    var otherTeam: String
    /// The web never sends a title.
    var title: String?
    var gameDate: GameDate?
    var location: String?
    var level: String?
    var notes: String?
    /// `"dark"`, `"light"` or `"#rrggbb"` (lower-case hex) from the form.
    var scoutedColor: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scoutedTeam = "scouted_team"
        case otherTeam = "other_team"
        case title
        case gameDate = "game_date"
        case location
        case level
        case notes
        case scoutedColor = "scouted_color"
    }

    init(
        scoutedTeam: String,
        otherTeam: String = "",
        title: String? = nil,
        gameDate: GameDate? = nil,
        location: String? = nil,
        level: String? = nil,
        notes: String? = nil,
        scoutedColor: String? = nil
    ) {
        self.scoutedTeam = scoutedTeam
        self.otherTeam = otherTeam
        self.title = title
        self.gameDate = gameDate
        self.location = location
        self.level = level
        self.notes = notes
        self.scoutedColor = scoutedColor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scoutedTeam = try container.decode(String.self, forKey: .scoutedTeam)
        otherTeam = try container.decodeIfPresent(String.self, forKey: .otherTeam) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
        gameDate = try container.decodeIfPresent(GameDate.self, forKey: .gameDate)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        scoutedColor = try container.decodeIfPresent(String.self, forKey: .scoutedColor)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scoutedTeam, forKey: .scoutedTeam)
        try container.encode(otherTeam, forKey: .otherTeam)
        try container.encode(title, forKey: .title)
        try container.encode(gameDate, forKey: .gameDate)
        try container.encode(location, forKey: .location)
        try container.encode(level, forKey: .level)
        try container.encode(notes, forKey: .notes)
        try container.encode(scoutedColor, forKey: .scoutedColor)
    }

    /// The web form's clean-up (03 §7.2, upload.js:60-82): every text trimmed; `other_team` `""` when empty;
    /// empty optional fields become nil. A blank `scouted_team` stays blank: refuse it before sending
    /// ("Team name needed").
    func normalized() -> GameCreate {
        GameCreate(
            scoutedTeam: FormText.trimmed(scoutedTeam),
            otherTeam: FormText.trimmed(otherTeam),
            title: FormText.trimmedOrNil(title),
            gameDate: gameDate,
            location: FormText.trimmedOrNil(location),
            level: FormText.trimmedOrNil(level),
            notes: FormText.trimmedOrNil(notes),
            scoutedColor: FormText.trimmedOrNil(scoutedColor))
    }
}
