import Foundation

/// `GET /api/games/{id}/export/fastscout-notes?side=` (01 §4.8, 03 §6.3): what to check before pasting into
/// FastScout, and the team numbers typed in by hand. Warnings may contain player names.
nonisolated struct FastScoutNotes: Codable, Hashable, Sendable {
    /// Plain sentences shown under "Check before pasting"; may be empty.
    var warnings: [String]
    /// Multi-line plain text (`\n`); show it monospaced.
    var teamNumbers: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case warnings
        case teamNumbers = "team_numbers"
    }

    init(warnings: [String] = [], teamNumbers: String = "") {
        self.warnings = warnings
        self.teamNumbers = teamNumbers
    }
}
