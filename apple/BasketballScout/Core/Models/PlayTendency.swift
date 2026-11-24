import Foundation

/// One play tendency (01 §4.7). All free text (`play_type` is not the `PlayType` enum).
nonisolated struct PlayTendency: Codable, Hashable, Sendable {
    var playType: String
    var frequency: String
    var effectiveness: String
    var counter: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case playType = "play_type"
        case frequency
        case effectiveness
        case counter
    }
}
