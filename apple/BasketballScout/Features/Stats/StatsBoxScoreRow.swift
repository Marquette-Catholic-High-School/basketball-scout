import Foundation

/// One row of a team's box score table (06 §9): a player line, the "Team / unidentified" line or the
/// "Totals" line, with the web's cell texts and sort values.
nonisolated struct StatsBoxScoreRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A roster player (or an unrostered jersey with a stat).
        case player
        /// `team_unattributed`: stats the analysis could not tie to a player.
        case team
        /// `totals`: players plus the team line.
        case totals
    }

    /// `"<side>:<index>"` for players (the server order), `"<side>:team"`, `"<side>:totals"`. Jerseys and
    /// player ids are not unique enough (an unrostered jersey has no id).
    let id: String
    let kind: Kind
    let line: BoxScoreLine
    /// Position in the server's order; ties keep it (the web's sort is stable).
    let order: Int

    init(id: String, kind: Kind, line: BoxScoreLine, order: Int) {
        self.id = id
        self.kind = kind
        self.line = line
        self.order = order
    }

    /// "Did not play" (boxscore.js `didNotPlay`): only player lines are ever muted as DNP.
    var isDNP: Bool { kind == .player && line.isDNP }

    /// The Player cell: the roster name, else the server's label ("#14", "Unknown player"); the team and
    /// totals lines are "Team / unidentified" and "Totals" (boxscore.js `table`).
    var name: String {
        switch kind {
        case .player:
            if let name = line.player.name, !name.isEmpty { return name }
            return line.player.label
        case .team: return Self.teamLineName
        case .totals: return Self.totalsLineName
        }
    }

    /// The "#" cell: the jersey as typed ("0" and "00" differ), empty for the team and totals lines.
    var jersey: String {
        kind == .player ? (line.player.jersey ?? "") : ""
    }

    /// "#14 Test Player 3", "#14", "Team / unidentified", "Totals": the row's title in lists and sheets.
    var title: String {
        guard kind == .player else { return name }
        if let name = line.player.name, !name.isEmpty {
            return jersey.isEmpty ? name : "#\(jersey) \(name)"
        }
        return line.player.label
    }

    /// The cell text of `column`, exactly as the web writes it (boxscore.js `COLUMNS[].show`).
    func text(_ column: StatsBoxScoreColumn) -> String {
        let line = line
        switch column {
        case .jersey: return jersey
        case .player: return name
        case .minutes: return isDNP ? Self.didNotPlayText : ScoutFormat.number(line.minutesEst, digits: 1)
        case .points: return String(line.pts)
        case .fieldGoals: return ScoutFormat.madeAttempted(made: line.fgm, attempts: line.fga)
        case .fieldGoalPercent: return ScoutFormat.percent(line.fgPct)
        case .threePointers: return ScoutFormat.madeAttempted(made: line.tpm, attempts: line.tpa)
        case .threePointPercent: return ScoutFormat.percent(line.tpPct)
        case .freeThrows: return ScoutFormat.madeAttempted(made: line.ftm, attempts: line.fta)
        case .freeThrowPercent: return ScoutFormat.percent(line.ftPct)
        case .offensiveRebounds: return String(line.oreb)
        case .defensiveRebounds: return String(line.dreb)
        case .rebounds: return String(line.reb)
        case .assists: return String(line.ast)
        case .steals: return String(line.stl)
        case .blocks: return String(line.blk)
        case .turnovers: return String(line.tov)
        case .fouls: return String(line.pf)
        case .plusMinus: return ScoutFormat.plusMinus(line.plusMinus)
        }
    }

    /// What VoiceOver says for a cell: "DNP" as "Did not play", "–" as "none", percentages and
    /// made-attempted pairs in words.
    func spokenText(_ column: StatsBoxScoreColumn) -> String {
        let text = text(column)
        if column == .minutes, isDNP { return Self.didNotPlayHelp }
        if text == ScoutFormat.placeholder { return "none" }
        switch column {
        case .fieldGoals, .threePointers, .freeThrows:
            let parts = text.split(separator: "-")
            if parts.count == 2 { return "\(parts[0]) of \(parts[1])" }
            return text
        case .jersey:
            return text.isEmpty ? "" : "number \(text)"
        default:
            return text
        }
    }

    /// A sort key: numbers compare as numbers, text with the locale (boxscore.js `sortLines`).
    enum SortValue: Hashable, Sendable {
        case number(Double)
        case text(String)
    }

    /// The value the web sorts `column` by (boxscore.js `COLUMNS[].value`): jersey number × 10 + length
    /// with no jersey last (∞), the lower-cased name, missing minutes and percentages as -1, a missing
    /// plus-minus as -∞, made shots for the made-attempted columns.
    func sortValue(_ column: StatsBoxScoreColumn) -> SortValue {
        let line = line
        switch column {
        case .jersey:
            let key = Jersey.sortKey(line.player.jersey)
            return .number(key == Int.max ? .infinity : Double(key))
        case .player:
            let name = (line.player.name.flatMap { $0.isEmpty ? nil : $0 } ?? line.player.label).lowercased()
            return .text(name)
        case .minutes: return .number(line.minutesEst ?? -1)
        case .points: return .number(Double(line.pts))
        case .fieldGoals: return .number(Double(line.fgm))
        case .fieldGoalPercent: return .number(line.fgPct ?? -1)
        case .threePointers: return .number(Double(line.tpm))
        case .threePointPercent: return .number(line.tpPct ?? -1)
        case .freeThrows: return .number(Double(line.ftm))
        case .freeThrowPercent: return .number(line.ftPct ?? -1)
        case .offensiveRebounds: return .number(Double(line.oreb))
        case .defensiveRebounds: return .number(Double(line.dreb))
        case .rebounds: return .number(Double(line.reb))
        case .assists: return .number(Double(line.ast))
        case .steals: return .number(Double(line.stl))
        case .blocks: return .number(Double(line.blk))
        case .turnovers: return .number(Double(line.tov))
        case .fouls: return .number(Double(line.pf))
        case .plusMinus: return .number(line.plusMinus.map(Double.init) ?? -.infinity)
        }
    }

    /// The player as the shot chart's player filter knows them (only for player rows with shots).
    var shotChartPlayerKey: String? {
        kind == .player ? StatsShotChartModel.playerKey(line.player) : nil
    }

    static let teamLineName = "Team / unidentified"
    static let totalsLineName = "Totals"
    static let didNotPlayText = "DNP"
    /// The muted row's tooltip (boxscore.js `line`).
    static let didNotPlayHelp = "Did not play"
}
