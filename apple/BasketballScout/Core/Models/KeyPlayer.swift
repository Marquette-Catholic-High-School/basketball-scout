import Foundation

/// One player to know (01 §4.7). `jersey` may arrive as `"#5"` or `"5"`; the web shows it as sent.
nonisolated struct KeyPlayer: Codable, Hashable, Sendable {
    var jersey: String
    var name: String
    var role: String
    var threatLevel: ThreatLevel
    var strengths: [String]
    var weaknesses: [String]
    var howToDefend: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case jersey
        case name
        case role
        case threatLevel = "threat_level"
        case strengths
        case weaknesses
        case howToDefend = "how_to_defend"
    }
}
