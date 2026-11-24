import Foundation

nonisolated extension ScoutFormat {
    // MARK: - Joining and small text helpers (06 §13.2, 07 §5.5)

    /// Non-empty parts joined with " · " (the web's `[…].filter(Boolean).join(" · ")`).
    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }.joined(separator: separator)
    }

    /// A machine code made readable: underscores become spaces ("left_corner" → "left corner").
    static func humanize(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Team name shorteners (06 §13.3, `labels.js`)

    /// The web's `shortTeamName(name, max = 12)` for chips: the trimmed name when it fits; else its
    /// first word without punctuation other than ' and - when that has 4…max characters; else the
    /// first letters of all words, uppercased, at most 4. "Riverside Academy HS" → "Riverside",
    /// "St. Anne's Prep Academy" → "SAPA". Like the web, letters outside ASCII are dropped from the
    /// first word ("\w" is ASCII-only) and lengths count UTF-16 units.
    static func shortTeamName(_ name: String?, maxLength: Int = 12) -> String {
        let text = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf16.count <= maxLength { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let firstWord = words.first else { return text }
        let first = String(firstWord.filter { isASCIIWordCharacter($0) || $0 == "'" || $0 == "-" })
        if first.utf16.count >= 4 && first.utf16.count <= maxLength { return first }
        let initials = words.compactMap(\.first).map(String.init).joined().uppercased()
        return String(initials.prefix(4))
    }

    /// The web's `teamAbbr(name)` for possession chips: ASCII letters, digits, "_" and spaces kept;
    /// several words → their initials, one word → its first 3 characters; uppercased, at most 3;
    /// nothing left → "?". "Riverside Academy" → "RA", "Eastwood" → "EAS", "St. Anne's Prep" → "SAP".
    static func teamAbbreviation(_ name: String?) -> String {
        let kept = String((name ?? "").filter { isASCIIWordCharacter($0) || $0.isWhitespace })
        let words = kept.split(whereSeparator: \.isWhitespace)
        guard let firstWord = words.first else { return "?" }
        let raw = words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : String(firstWord.prefix(3))
        return String(raw.uppercased().prefix(3))
    }

    /// JavaScript's `\w` without the `u` flag: ASCII letters, digits and "_".
    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_": return true
        default: return false
        }
    }
}
