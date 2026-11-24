import Foundation

/// Field lengths the server accepts, and the web's `maxlength` behaviour for them: text past the limit is
/// dropped as it is typed or pasted, so the server never answers 422 for a long name (03 §1.5).
nonisolated enum NewGameTextLimit {
    /// `scouted_team` and `other_team` (1–120 / ≤ 120).
    static let teamName = 120
    /// `location` (≤ 200).
    static let location = 200
    /// `level` (≤ 40).
    static let level = 40
    /// `notes` (≤ 5000).
    static let notes = 5000
    /// The video link (≤ 2000 before trimming, 04 §3).
    static let videoLink = 2000

    /// `text` cut to at most `maxCodePoints` Unicode code points (pydantic counts code points, 01 §1.4),
    /// never splitting a character (an emoji flag or an accented letter stays whole or goes).
    static func clamp(_ text: String, maxCodePoints: Int) -> String {
        guard text.unicodeScalars.count > maxCodePoints else { return text }
        var result = ""
        var count = 0
        for character in text {
            let length = character.unicodeScalars.count
            guard count + length <= maxCodePoints else { break }
            result.append(character)
            count += length
        }
        return result
    }
}
