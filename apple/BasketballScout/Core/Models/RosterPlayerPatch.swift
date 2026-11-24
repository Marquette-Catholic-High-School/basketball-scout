import Foundation

/// Body of `PATCH /api/games/{id}/rosters/{side}/players/{player_id}` → 200 `Roster` (01 §4.5, 05 §4.6).
/// Only keys that are present change; the merged player is then re-validated. The id cannot change.
///
/// What `.null` does per field (09 D1 #3, R26):
/// - `jersey`: the server refuses null (422), so encoding `.null` throws. A value must match `^\d{1,2}$`.
/// - `firstName`, `lastName`: the server refuses null, so `.null` is sent as `""` (clears the name).
/// - `position`, `grade`, `height`, `notes`, `fastscoutName`: cleared.
nonisolated struct RosterPlayerPatch: Codable, Hashable, Sendable {
    var jersey: Patch<String>
    var firstName: Patch<String>
    var lastName: Patch<String>
    var position: Patch<String>
    var grade: Patch<String>
    var height: Patch<String>
    var notes: Patch<String>
    var fastscoutName: Patch<String>

    enum CodingKeys: String, CodingKey, CaseIterable {
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
        jersey: Patch<String> = .unset,
        firstName: Patch<String> = .unset,
        lastName: Patch<String> = .unset,
        position: Patch<String> = .unset,
        grade: Patch<String> = .unset,
        height: Patch<String> = .unset,
        notes: Patch<String> = .unset,
        fastscoutName: Patch<String> = .unset
    ) {
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
        jersey = try container.decode(Patch<String>.self, forKey: .jersey)
        firstName = try container.decode(Patch<String>.self, forKey: .firstName)
        lastName = try container.decode(Patch<String>.self, forKey: .lastName)
        position = try container.decode(Patch<String>.self, forKey: .position)
        grade = try container.decode(Patch<String>.self, forKey: .grade)
        height = try container.decode(Patch<String>.self, forKey: .height)
        notes = try container.decode(Patch<String>.self, forKey: .notes)
        fastscoutName = try container.decode(Patch<String>.self, forKey: .fastscoutName)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if jersey.isNull {
            throw EncodingError.invalidValue(jersey, EncodingError.Context(
                codingPath: container.codingPath + [CodingKeys.jersey],
                debugDescription: "jersey cannot be null: the server answers 422 (09 R26). Leave it .unset."))
        }
        try container.encode(jersey, forKey: .jersey)
        try container.encode(firstName.isNull ? .value("") : firstName, forKey: .firstName)
        try container.encode(lastName.isNull ? .value("") : lastName, forKey: .lastName)
        try container.encode(position, forKey: .position)
        try container.encode(grade, forKey: .grade)
        try container.encode(height, forKey: .height)
        try container.encode(notes, forKey: .notes)
        try container.encode(fastscoutName, forKey: .fastscoutName)
    }

    /// No field is set: the body is `{}` (a no-op).
    var isEmpty: Bool {
        jersey.isUnset && firstName.isUnset && lastName.isUnset && position.isUnset && grade.isUnset
            && height.isUnset && notes.isUnset && fastscoutName.isUnset
    }
}
