import Foundation

/// A roster player as the server returns it (01 §4.5, 05 §5.2): an element of `Roster.players`.
///
/// Players are minors: never log or print these fields. To send players (`PUT /rosters/{side}`,
/// `POST …/players`) use `RosterPlayerInput`, which can leave `id` out so the server makes one (09 R42).
nonisolated struct RosterPlayer: Codable, Hashable, Sendable, Identifiable {
    /// `p_` + 12 hex when the server made it; any string a client sent otherwise.
    var id: String
    /// One or two ASCII digits as typed: `"0"`, `"00"` and `"05"` are different jerseys. Never an Int.
    var jersey: String
    /// Never null (`""` when empty).
    var firstName: String
    /// Never null (`""` when empty).
    var lastName: String
    var position: String?
    /// The importer normalises known grades to `Fr`/`So`/`Jr`/`Sr`.
    var grade: String?
    var height: String?
    var notes: String?
    /// Exact spelling in the coach's FastScout roster (paste matching is by name).
    var fastscoutName: String?
    /// Server-computed: trimmed first and last name joined by a space, empty parts skipped; `""` if both are empty.
    var name: String

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
        case name
    }

    init(
        id: String,
        jersey: String,
        firstName: String = "",
        lastName: String = "",
        position: String? = nil,
        grade: String? = nil,
        height: String? = nil,
        notes: String? = nil,
        fastscoutName: String? = nil,
        name: String? = nil
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
        self.name = name ?? Self.fullName(firstName: firstName, lastName: lastName)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        jersey = try container.decode(String.self, forKey: .jersey)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        grade = try container.decodeIfPresent(String.self, forKey: .grade)
        height = try container.decodeIfPresent(String.self, forKey: .height)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        fastscoutName = try container.decodeIfPresent(String.self, forKey: .fastscoutName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? Self.fullName(firstName: firstName, lastName: lastName)
    }

    /// The server's `name` rule (schemas.py:581-584).
    static func fullName(firstName: String, lastName: String) -> String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// This player as a request element, keeping its id.
    var input: RosterPlayerInput {
        RosterPlayerInput(
            id: id, jersey: jersey, firstName: firstName, lastName: lastName, position: position, grade: grade,
            height: height, notes: notes, fastscoutName: fastscoutName)
    }
}
