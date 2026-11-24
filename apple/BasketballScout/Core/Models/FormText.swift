import Foundation

/// The web forms' text clean-up before a request (03 §7.2, 05 §7.2; 09 D1 #3: the server does not trim).
nonisolated enum FormText {
    /// Leading and trailing whitespace and newlines removed.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed, or nil when nothing is left: the web sends `null` for an empty optional field.
    static func trimmedOrNil(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = trimmed(text)
        return result.isEmpty ? nil : result
    }
}
