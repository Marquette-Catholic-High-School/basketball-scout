import Foundation

/// How often and how well a team ran (or played) one play type (01 §4.9, 06 §3.11). Sorted by side
/// (scouted, other, null), offense first, count descending. The web ignores rows with a null side.
nonisolated struct PlayTypeSummary: Codable, Hashable, Sendable {
    var type: PlayType
    var category: PlayCategory
    var side: TeamSide?
    var count: Int
    /// Share of the side's possessions with this play (defense: of the other side's), 0–1.
    var possessionsPct: Double?
    /// Offense: scored; defense: allowed.
    var points: Int
    /// Points per featured possession.
    var ppp: Double?
    var fgm: Int
    var fga: Int
    var turnovers: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case category
        case side
        case count
        case possessionsPct = "possessions_pct"
        case points
        case ppp
        case fgm
        case fga
        case turnovers
    }
}
