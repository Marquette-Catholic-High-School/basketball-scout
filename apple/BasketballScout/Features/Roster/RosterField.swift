import Foundation

/// One editable cell of a roster row, in the web's column order (roster.js:10-19).
nonisolated enum RosterField: String, CaseIterable, Hashable, Sendable {
    case jersey
    case firstName
    case lastName
    case fastscoutName
    case position
    case grade
    case height
    case notes

    /// The table's column header, as the web writes it: "#", "First name", …, "Pos", "Gr", "Ht", "Notes".
    var columnTitle: String {
        switch self {
        case .jersey: "#"
        case .firstName: "First name"
        case .lastName: "Last name"
        case .fastscoutName: "FastScout name"
        case .position: "Pos"
        case .grade: "Gr"
        case .height: "Ht"
        case .notes: "Notes"
        }
    }

    /// The field's name in words (forms and VoiceOver): the import's column labels ("Jersey", "Position", …).
    var label: String { Labels.importColumnLabel(for: serverKey) }

    /// The `RosterPlayer` key of this field.
    var serverKey: String {
        switch self {
        case .jersey: "jersey"
        case .firstName: "first_name"
        case .lastName: "last_name"
        case .fastscoutName: "fastscout_name"
        case .position: "position"
        case .grade: "grade"
        case .height: "height"
        case .notes: "notes"
        }
    }

    /// The web inputs' `maxlength`: 3 for the jersey ("#12"), 120 for the others (roster.js:163).
    var maxLength: Int { self == .jersey ? 3 : 120 }

    /// What a typed change leaves in the field, or nil when the change is refused (the field keeps `old`).
    ///
    /// Like a web input's `maxlength`: text past the limit is cut, and nothing more fits into a full field
    /// (a longer value loaded from the server stays as it is; deleting always works). The jersey keeps only
    /// digits, `#` and spaces, with any decimal digit turned into its ASCII one (09 R41: some keyboards type
    /// "٥"; the server would accept it, film matching would not).
    func accept(_ typed: String, replacing old: String) -> String? {
        Self.limit(self == .jersey ? Self.jerseyCharacters(typed) : typed, replacing: old, maxLength: maxLength)
    }

    /// The team name's `maxlength` (the server's limit, 05 §4.3).
    static let teamNameMaxLength = 120

    /// `maxlength` for any field: `text`, cut to `maxLength` when it grew past it; nil when the field was
    /// already full (nothing more fits). Shrinking is always accepted.
    static func limit(_ text: String, replacing old: String, maxLength: Int) -> String? {
        guard text.count > maxLength, text.count > old.count else { return text }
        return old.count >= maxLength ? nil : String(text.prefix(maxLength))
    }

    /// `typed` with ASCII digits for any decimal digit and nothing but digits, `#` and spaces.
    static func jerseyCharacters(_ typed: String) -> String {
        String(typed.compactMap { character -> Character? in
            if let digit = asciiDigit(character) { return digit }
            return character == "#" || character == " " ? character : nil
        })
    }

    private static func asciiDigit(_ character: Character) -> Character? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              scalar.properties.numericType == .decimal, let value = character.wholeNumberValue,
              (0...9).contains(value)
        else { return nil }
        return Character(String(value))
    }
}
