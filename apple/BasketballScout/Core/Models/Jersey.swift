import Foundation

/// Jersey-number rules (01 §4.5, 05 §6.1, 09 D1 #4, R41). A jersey is a string of one or two ASCII digits:
/// `"0"`, `"00"` and `"05"` are three different jerseys, so never convert one to an Int for identity.
///
/// The server's pattern `^\d{1,2}$` also accepts non-ASCII digits (pydantic's `\d` is Unicode) and it never
/// refuses duplicates, so the client checks both, as the web does.
nonisolated enum Jersey {
    /// One or two ASCII digits (`0`–`9`), nothing else.
    static func isValid(_ jersey: String) -> Bool {
        let scalars = jersey.unicodeScalars
        return (1...2).contains(scalars.count) && scalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Trimmed, with a leading `#` and the spaces after it removed (the web's `/^#\s*/`, roster.js:179-183).
    static func stripped(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The jersey a coach typed, cleaned and checked: nil when it is not one or two ASCII digits.
    static func normalized(_ typed: String) -> String? {
        let text = stripped(typed)
        return isValid(text) ? text : nil
    }

    /// The number a jersey shows (`"05"` → 5). Two different jerseys with the same number (`"5"` / `"05"`)
    /// are allowed but worth a warning, as the importer gives (09 D1 #4).
    static func numericValue(_ jersey: String) -> Int? {
        isValid(jersey) ? Int(jersey) : nil
    }

    /// Sort key that puts jerseys in number order with `"0"` before `"00"` before `"1"`: number × 10 + length,
    /// non-numeric last (the box score's rule, boxscore.js; 06 §9).
    static func sortKey(_ jersey: String?) -> Int {
        guard let jersey, let number = numericValue(jersey) else { return Int.max }
        return number * 10 + jersey.count
    }
}
