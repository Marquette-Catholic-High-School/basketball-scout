import Foundation

/// The box score sort (boxscore.js `sortBy`): the server's order until a column is chosen; choosing the
/// active column flips the direction, another column starts at its first direction (# and Player
/// ascending, stats descending). Only player rows move; the team and totals lines stay at the bottom.
nonisolated struct StatsBoxScoreSort: Hashable, Sendable {
    /// nil: the server's order (roster players by jersey, then unrostered jerseys).
    var column: StatsBoxScoreColumn?
    var ascending: Bool

    init(column: StatsBoxScoreColumn? = nil, ascending: Bool = false) {
        self.column = column
        self.ascending = ascending
    }

    /// The server's order (the web's initial `{key: null, direction: "desc"}`).
    static let serverOrder = StatsBoxScoreSort()

    /// A click on `column`'s header.
    mutating func select(_ column: StatsBoxScoreColumn) {
        if self.column == column {
            ascending.toggle()
        } else {
            self.column = column
            ascending = column.firstSortAscending
        }
    }

    /// The state after a click on `column`.
    func selecting(_ column: StatsBoxScoreColumn) -> StatsBoxScoreSort {
        var copy = self
        copy.select(column)
        return copy
    }
}

/// One team's box score as the tab shows it (boxscore.js; 06 §9): player rows, the team line, the totals,
/// the summary line and the "Shooting by zone" table.
nonisolated struct StatsBoxScoreModel: Sendable {
    let box: TeamBoxScore
    /// Player rows in the server's order.
    let playerRows: [StatsBoxScoreRow]
    let teamRow: StatsBoxScoreRow
    let totalsRow: StatsBoxScoreRow

    init(box: TeamBoxScore) {
        self.box = box
        let side = box.side.rawValue
        playerRows = box.players.enumerated().map { index, line in
            StatsBoxScoreRow(id: "\(side):\(index)", kind: .player, line: line, order: index)
        }
        teamRow = StatsBoxScoreRow(id: "\(side):team", kind: .team, line: box.teamUnattributed, order: box.players.count)
        totalsRow = StatsBoxScoreRow(id: "\(side):totals", kind: .totals, line: box.totals, order: box.players.count + 1)
    }

    /// The table's rows: the players in `sort` order, then the team line and the totals.
    func rows(sortedBy sort: StatsBoxScoreSort, locale: Locale = .current) -> [StatsBoxScoreRow] {
        Self.sorted(playerRows, by: sort, locale: locale) + [teamRow, totalsRow]
    }

    /// The row with `id` (players, team line or totals).
    func row(id: StatsBoxScoreRow.ID) -> StatsBoxScoreRow? {
        if teamRow.id == id { return teamRow }
        if totalsRow.id == id { return totalsRow }
        return playerRows.first { $0.id == id }
    }

    /// Player rows sorted like the web (boxscore.js `sortLines`): numbers compare as numbers, the name with
    /// the locale; equal values keep the server's order (a stable sort).
    static func sorted(_ rows: [StatsBoxScoreRow], by sort: StatsBoxScoreSort, locale: Locale = .current) -> [StatsBoxScoreRow] {
        guard let column = sort.column else { return rows }
        return rows.sorted { lhs, rhs in
            let result = compare(lhs.sortValue(column), rhs.sortValue(column), locale: locale)
            if result != .orderedSame {
                return sort.ascending ? result == .orderedAscending : result == .orderedDescending
            }
            return lhs.order < rhs.order
        }
    }

    /// JavaScript's `(a > b) - (a < b)` for numbers and `localeCompare` for text.
    static func compare(_ lhs: StatsBoxScoreRow.SortValue, _ rhs: StatsBoxScoreRow.SortValue, locale: Locale) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        case let (.text(a), .text(b)):
            return a.compare(b, options: [], range: nil, locale: locale)
        case (.number, .text):
            return .orderedAscending
        case (.text, .number):
            return .orderedDescending
        }
    }

    // MARK: - Summary and texts

    /// "Points: 25", "Possessions: 24", "Points per possession: 1.04" (boxscore.js `draw`).
    var summary: [StatsFact] {
        [
            StatsFact(label: "Points", value: String(box.totals.pts)),
            StatsFact(label: "Possessions", value: String(box.possessions)),
            StatsFact(label: "Points per possession", value: ScoutFormat.number(box.pointsPerPossession, digits: 2)),
        ]
    }

    /// The table's caption for VoiceOver ("Test Team A box score").
    var caption: String { "\(box.teamName) box score" }

    /// Nobody on the roster or the film yet (the table shows `emptyPlayersMessage` instead of players).
    var hasPlayers: Bool { !playerRows.isEmpty }

    static let emptyPlayersMessage = "No identified players yet - match jerseys on the roster page."
    static let noBoxScoreMessage = "No box score in this analysis."
    /// The tab's hint (game.html), without the last sentence, which depends on the layout.
    static let hint = "MIN is approximate on-floor video time (includes stoppages). DNP: no stats and under a minute on the film (the FastScout paste leaves these players out). Stats the analysis couldn't tie to a player go on the Team line."

    // MARK: - Shooting by zone (boxscore.js `zoneTable`)

    /// The zone table's rows: players who played (in the server's order, named by their label), the team
    /// line, then the totals.
    var zoneRows: [StatsBoxScoreZoneRow] {
        let players = playerRows.filter { !$0.isDNP }.map {
            StatsBoxScoreZoneRow(id: $0.id, kind: .player, name: $0.line.player.label, zones: $0.line.zones)
        }
        return players + [
            StatsBoxScoreZoneRow(id: teamRow.id, kind: .team, name: StatsBoxScoreRow.teamLineName, zones: box.teamUnattributed.zones),
            StatsBoxScoreZoneRow(id: totalsRow.id, kind: .totals, name: StatsBoxScoreRow.totalsLineName, zones: box.totals.zones),
        ]
    }

    // MARK: - Choosing the team

    /// The team shown (boxscore.js `render`): the remembered side while the analysis has it, else the first
    /// box score (the scouted team first); nil without any box score.
    static func side(in analysis: GameAnalysis, preferred: TeamSide?) -> TeamSide? {
        if let preferred, analysis.boxScores.contains(where: { $0.side == preferred }) { return preferred }
        return analysis.boxScores.first?.side
    }

    // MARK: - Copy

    /// The rows as tab-separated text with a header line, for pasting into a spreadsheet.
    static func tabSeparated(_ rows: [StatsBoxScoreRow]) -> String {
        let columns = StatsBoxScoreColumn.allCases
        let header = columns.map(\.title).joined(separator: "\t")
        let lines = rows.map { row in columns.map { row.text($0) }.joined(separator: "\t") }
        return ([header] + lines).joined(separator: "\n")
    }
}

/// One row of "Shooting by zone" (boxscore.js `zoneTable`).
nonisolated struct StatsBoxScoreZoneRow: Identifiable, Hashable, Sendable {
    let id: String
    let kind: StatsBoxScoreRow.Kind
    let name: String
    let zones: ZoneSplits

    /// The columns in the web's order: Paint, Mid-range, 3-point, No location.
    static let zones: [ShotZone] = [.paint, .mid, .three, .unknownZone]

    /// "5-12 (42%)" with the server's percentage at 0 decimals, or "–" with no attempts.
    func text(_ zone: ShotZone) -> String {
        guard let split = zones[zone], split.attempts > 0 else { return ScoutFormat.placeholder }
        return ScoutFormat.shootingSplit(made: split.made, attempts: split.attempts, fraction: split.pct)
    }

    /// The cell for VoiceOver: "5 of 12, 42%", or "none".
    func spokenText(_ zone: ShotZone) -> String {
        guard let split = zones[zone], split.attempts > 0 else { return "none" }
        return "\(split.made) of \(split.attempts), \(ScoutFormat.percent(split.pct, digits: 0))"
    }
}
