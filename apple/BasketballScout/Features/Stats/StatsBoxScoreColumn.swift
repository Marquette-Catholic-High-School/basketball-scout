import Foundation

/// The box score's columns in the web's order (boxscore.js `COLUMNS`; 06 §9). `Labels` has no box score
/// table, so the headers live here, word for word as the web writes them.
nonisolated enum StatsBoxScoreColumn: String, CaseIterable, Identifiable, Hashable, Sendable {
    case jersey
    case player
    case minutes
    case points
    case fieldGoals
    case fieldGoalPercent
    case threePointers
    case threePointPercent
    case freeThrows
    case freeThrowPercent
    case offensiveRebounds
    case defensiveRebounds
    case rebounds
    case assists
    case steals
    case blocks
    case turnovers
    case fouls
    case plusMinus

    var id: String { rawValue }

    /// The column header (boxscore.js).
    var title: String {
        switch self {
        case .jersey: "#"
        case .player: "Player"
        case .minutes: "MIN"
        case .points: "PTS"
        case .fieldGoals: "FG"
        case .fieldGoalPercent: "FG%"
        case .threePointers: "3PT"
        case .threePointPercent: "3P%"
        case .freeThrows: "FT"
        case .freeThrowPercent: "FT%"
        case .offensiveRebounds: "OREB"
        case .defensiveRebounds: "DREB"
        case .rebounds: "REB"
        case .assists: "AST"
        case .steals: "STL"
        case .blocks: "BLK"
        case .turnovers: "TO"
        case .fouls: "PF"
        case .plusMinus: "+/-"
        }
    }

    /// The abbreviation in words: what VoiceOver says for the header, the sort menu and the player detail.
    var name: String {
        switch self {
        case .jersey: "Jersey"
        case .player: "Player"
        case .minutes: "Minutes"
        case .points: "Points"
        case .fieldGoals: "Field goals"
        case .fieldGoalPercent: "Field goal percentage"
        case .threePointers: "3-pointers"
        case .threePointPercent: "3-point percentage"
        case .freeThrows: "Free throws"
        case .freeThrowPercent: "Free throw percentage"
        case .offensiveRebounds: "Offensive rebounds"
        case .defensiveRebounds: "Defensive rebounds"
        case .rebounds: "Rebounds"
        case .assists: "Assists"
        case .steals: "Steals"
        case .blocks: "Blocks"
        case .turnovers: "Turnovers"
        case .fouls: "Fouls"
        case .plusMinus: "Plus-minus"
        }
    }

    /// The header's tooltip (the web's `title`): only MIN has one.
    var help: String? {
        self == .minutes ? "Approximate on-floor video minutes" : nil
    }

    /// Sorted as text (locale order of the lower-cased name); every other column sorts as numbers.
    var sortsAsText: Bool { self == .player }

    /// The first click sorts ascending for "#" and "Player", descending for the stats (boxscore.js `sortBy`).
    var firstSortAscending: Bool { self == .jersey || self == .player }

    /// Right-aligned numbers (the web's `num` class): every column but "#" and "Player".
    var isNumeric: Bool { self != .jersey && self != .player }

    /// The stat columns (everything after the player's name).
    static let statColumns: [StatsBoxScoreColumn] = allCases.filter(\.isNumeric)
}
