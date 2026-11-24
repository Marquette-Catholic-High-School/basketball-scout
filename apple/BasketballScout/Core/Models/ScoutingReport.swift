import Foundation

/// The structured scouting report Claude wrote (01 §4.7, 03 §1.6). Every key is required and never null;
/// lists may be empty (the web leaves empty sections out).
nonisolated struct ScoutingReport: Codable, Hashable, Sendable {
    /// One sentence.
    var headline: String
    /// Paragraphs separated by a blank line (`\n\n`).
    var executiveSummary: String
    var offensiveIdentity: [String]
    var defensiveIdentity: [String]
    /// Usually 3–6, most dangerous first.
    var keyPlayers: [KeyPlayer]
    var playTendencies: [PlayTendency]
    var transition: [String]
    var specialSituations: [String]
    /// An ordered list in the web.
    var keysToWin: [String]
    var defensiveGamePlan: [String]
    var offensiveGamePlan: [String]
    var practiceEmphasis: [String]
    /// Shown muted, last.
    var dataCaveats: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case headline
        case executiveSummary = "executive_summary"
        case offensiveIdentity = "offensive_identity"
        case defensiveIdentity = "defensive_identity"
        case keyPlayers = "key_players"
        case playTendencies = "play_tendencies"
        case transition
        case specialSituations = "special_situations"
        case keysToWin = "keys_to_win"
        case defensiveGamePlan = "defensive_game_plan"
        case offensiveGamePlan = "offensive_game_plan"
        case practiceEmphasis = "practice_emphasis"
        case dataCaveats = "data_caveats"
    }

    /// `executiveSummary` split into paragraphs on blank lines (report.js).
    var summaryParagraphs: [String] {
        executiveSummary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
