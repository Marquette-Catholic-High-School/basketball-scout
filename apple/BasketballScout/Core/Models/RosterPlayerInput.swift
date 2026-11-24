import Foundation

/// A player as the client sends it: an element of `RosterReplace.players` and the body of
/// `POST /api/games/{id}/rosters/{side}/players` (01 §4.5, 05 §4.3, §4.5).
///
/// - `id`: nil for a new player, so the server makes a `p_…` id (09 R42); left out of the body then (null
///   is not a valid id). Keep the server's ids afterwards: track overrides reference them.
/// - `jersey`, `first_name`, `last_name`: never null (09 D1 #3, R26); names are `""` when empty.
/// - Optional fields are sent as null when empty, as the web's roster editor does (05 §7.2).
nonisolated struct RosterPlayerInput: Codable, Hashable, Sendable {
    var id: String?
    var jersey: String
    var firstName: String
    var lastName: String
    var position: String?
    var grade: String?
    var height: String?
    var notes: String?
    var fastscoutName: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case jersey
        case firstName = "first_name"
        case lastName = "last_name"
        case position
        case grade
        case height
        case notes
        case fastscoutName = "fastscout_name"
    }

    init(
        id: String? = nil,
        jersey: String,
        firstName: String = "",
        lastName: String = "",
        position: String? = nil,
        grade: String? = nil,
        height: String? = nil,
        notes: String? = nil,
        fastscoutName: String? = nil
    ) {
        self.id = id
        self.jersey = jersey
        self.firstName = firstName
        self.lastName = lastName
        self.position = position
        self.grade = grade
        self.height = height
        self.notes = notes
        self.fastscoutName = fastscoutName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        jersey = try container.decode(String.self, forKey: .jersey)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        position = try container.decodeIfPresent(String.self, forKey: .position)
        grade = try container.decodeIfPresent(String.self, forKey: .grade)
        height = try container.decodeIfPresent(String.self, forKey: .height)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        fastscoutName = try container.decodeIfPresent(String.self, forKey: .fastscoutName)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(jersey, forKey: .jersey)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(position, forKey: .position)
        try container.encode(grade, forKey: .grade)
        try container.encode(height, forKey: .height)
        try container.encode(notes, forKey: .notes)
        try container.encode(fastscoutName, forKey: .fastscoutName)
    }

    /// The web editor's clean-up before saving (05 §7.2 step 1–3, roster.js:172-194): every field trimmed,
    /// a leading `#` (and spaces) removed from the jersey, empty optional fields nil, empty names `""`.
    /// It does not validate the jersey: check `Jersey.isValid` and duplicates before sending.
    func normalized() -> RosterPlayerInput {
        RosterPlayerInput(
            id: id,
            jersey: Jersey.stripped(jersey),
            firstName: FormText.trimmed(firstName),
            lastName: FormText.trimmed(lastName),
            position: FormText.trimmedOrNil(position),
            grade: FormText.trimmedOrNil(grade),
            height: FormText.trimmedOrNil(height),
            notes: FormText.trimmedOrNil(notes),
            fastscoutName: FormText.trimmedOrNil(fastscoutName))
    }

    /// Every editable cell is empty: the web skips such rows when saving (a saved player whose cells were
    /// all cleared is thereby removed; 05 §7.2).
    var isBlank: Bool {
        [jersey, firstName, lastName, position ?? "", grade ?? "", height ?? "", notes ?? "", fastscoutName ?? ""]
            .allSatisfy { FormText.trimmed($0).isEmpty }
    }
}
