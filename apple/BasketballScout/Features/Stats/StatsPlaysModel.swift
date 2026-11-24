import Foundation

/// Which list the plays tab shows under the play-type tables.
nonisolated enum StatsPlaysListMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// "Individual plays" (plays.js).
    case plays
    /// The possessions (the web shows them only as the marker band and timeline chips).
    case possessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plays: "Plays"
        case .possessions: "Possessions"
        }
    }
}

/// The plays tab's filters for one game (plays.js `#plays-filter-type`, `#plays-filter-side`).
nonisolated struct StatsPlaysFilters: Hashable, Sendable {
    var list: StatsPlaysListMode = .plays
    /// nil = "All play types".
    var type: PlayType?
    /// nil = "Both teams".
    var side: TeamSide?
    /// The possessions list's team; nil = both teams.
    var possessionSide: TeamSide?
}

/// One row of an "Offense" / "Defense" table (plays.js `summaryTable`).
nonisolated struct StatsPlaySummaryRow: Identifiable, Hashable, Sendable {
    let id: String
    /// "Pick & Roll", "Zone Defense".
    let title: String
    /// The zone shapes a team played, most frequent first: "2-3 ×4, 1-3-1 ×1" (Defense table only).
    let shapes: String?
    let count: String
    /// "38%" (0 decimals) or "–".
    let possessionsPercent: String
    let points: String
    /// "1.11" (2 decimals) or "–".
    let pointsPerPossession: String
    /// "5-9".
    let fieldGoals: String
    let turnovers: String

    /// The columns after the play type, in order, with their headers (plays.js).
    static let columnTitles = ["Count", "% Poss", "PTS", "PPP", "FG", "TO"]
    /// The headers in words for VoiceOver.
    static let columnNames = ["Count", "Share of possessions", "Points", "Points per possession", "Field goals", "Turnovers"]

    var values: [String] { [count, possessionsPercent, points, pointsPerPossession, fieldGoals, turnovers] }
}

/// One team's play-type tables (plays.js `drawSummary`).
nonisolated struct StatsPlaySummaryBlock: Identifiable, Hashable, Sendable {
    let side: TeamSide
    let offense: [StatsPlaySummaryRow]
    let defense: [StatsPlaySummaryRow]
    var id: String { side.rawValue }
}

/// One row of "Individual plays" (plays.js `drawList`).
nonisolated struct StatsPlayRow: Identifiable, Hashable, Sendable {
    let id: String
    let startT: Double
    /// `formatClock(start_t)`.
    let time: String
    /// The type's label plus " (2-3)" when the play has a zone shape.
    let title: String
    let side: TeamSide?
    /// "Ball handler: #3 Test Player 1 · Screener: #22 Test Player 2", in the server's role order.
    let players: String
    /// "Made FG", "No shot", "–".
    let outcome: String
    /// The points, or "" for none.
    let points: String
    /// "70%".
    let confidence: String
    /// Confidence under 0.5: shown faded (55 %).
    let isLowConfidence: Bool
    /// The server's sentence (the web's row tooltip).
    let description: String

    /// The time button's label (plays.js): "Watch play at 1:05".
    var watchLabel: String { "Watch play at \(time)" }
}

/// One possession (06 §3.7): the web lists none, the app adds a list (03 §7.3 brief).
nonisolated struct StatsPossessionRow: Identifiable, Hashable, Sendable {
    let id: Int
    let startT: Double
    /// "Possession 12".
    let title: String
    let side: TeamSide?
    /// `formatClock(start_t)`.
    let time: String
    /// "18 s" (`formatDuration` of the possession's length).
    let length: String
    /// "Made FG", "Free throws", "End of period".
    let outcome: String
    let points: Int
    /// "def rebound", "steal", … (the server's start reason in words); nil when empty.
    let startReason: String?
    let isTransition: Bool
    /// The offensive plays in it: "Pick & Roll, Spot-Up"; nil without any.
    let plays: String?

    /// "Watch possession at 1:05".
    var watchLabel: String { "Watch possession at \(time)" }
}

/// Everything the plays tab shows (plays.js; 06 §11).
nonisolated enum StatsPlaysModel {
    // MARK: Play-type tables

    /// One block per side with rows (scouted, then other); rows with no side are left out (plays.js).
    static func summaryBlocks(_ analysis: GameAnalysis) -> [StatsPlaySummaryBlock] {
        let plays = sortedPlays(analysis.plays)
        return [TeamSide.scouted, .other].compactMap { side in
            let offense = sortedByCount(analysis.playSummary.filter { $0.side == side && $0.category == .offense })
            let defense = sortedByCount(analysis.playSummary.filter { $0.side == side && $0.category == .defense })
            guard !offense.isEmpty || !defense.isEmpty else { return nil }
            return StatsPlaySummaryBlock(
                side: side,
                offense: offense.map { summaryRow($0, shapes: nil) },
                defense: defense.map { summaryRow($0, shapes: $0.type == .zoneDefense ? zoneShapes(plays, side: side) : nil) })
        }
    }

    /// Count descending; equal counts keep the server's order.
    private static func sortedByCount(_ rows: [PlayTypeSummary]) -> [PlayTypeSummary] {
        rows.enumerated().sorted { lhs, rhs in
            lhs.element.count != rhs.element.count ? lhs.element.count > rhs.element.count : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func summaryRow(_ summary: PlayTypeSummary, shapes: String?) -> StatsPlaySummaryRow {
        StatsPlaySummaryRow(
            id: "\(summary.side?.rawValue ?? ""):\(summary.category.rawValue):\(summary.type.rawValue)",
            title: summary.type.label,
            shapes: shapes.flatMap { $0.isEmpty ? nil : $0 },
            count: String(summary.count),
            possessionsPercent: ScoutFormat.percent(summary.possessionsPct, digits: 0),
            points: String(summary.points),
            pointsPerPossession: ScoutFormat.number(summary.ppp, digits: 2),
            fieldGoals: ScoutFormat.madeAttempted(made: summary.fgm, attempts: summary.fga),
            turnovers: String(summary.turnovers))
    }

    /// "2-3 ×4, 1-3-1 ×1" from `side`'s zone plays (plays.js `zoneShapes`): most frequent first, ties in
    /// order of appearance.
    static func zoneShapes(_ plays: [Play], side: TeamSide) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for play in plays where play.side == side && play.type == .zoneDefense {
            guard let shape = play.zoneShape, !shape.isEmpty else { continue }
            if counts[shape] == nil { order.append(shape) }
            counts[shape, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return a != b ? a > b : lhs.offset < rhs.offset
            }
            .map { "\($0.element) \u{00D7}\(counts[$0.element] ?? 0)" }
            .joined(separator: ", ")
    }

    static let noPlaysText = "No plays were recognised in this film."
    static let summaryHint = "% Poss is the share of that team's possessions with the play. For defenses, PTS and PPP are what the other team scored against it."

    // MARK: Individual plays

    /// Plays by start time; equal times keep the server's order (plays.js `render`).
    static func sortedPlays(_ plays: [Play]) -> [Play] {
        plays.enumerated().sorted { lhs, rhs in
            lhs.element.startT != rhs.element.startT ? lhs.element.startT < rhs.element.startT : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The Type filter's choices: the types present, in order of first appearance (plays.js `buildFilters`).
    static func typeOptions(_ sortedPlays: [Play]) -> [PlayType] {
        var seen = Set<PlayType>()
        return sortedPlays.compactMap { seen.insert($0.type).inserted ? $0.type : nil }
    }

    /// The filters in force: a play type that no longer occurs falls back to "All play types".
    static func validated(_ filters: StatsPlaysFilters, typeOptions: [PlayType]) -> StatsPlaysFilters {
        var filters = filters
        if let type = filters.type, !typeOptions.contains(type) { filters.type = nil }
        return filters
    }

    /// The listed plays (plays.js `drawList`).
    static func rows(_ sortedPlays: [Play], filters: StatsPlaysFilters) -> [StatsPlayRow] {
        sortedPlays
            .filter { play in
                (filters.type == nil || play.type == filters.type) && (filters.side == nil || play.side == filters.side)
            }
            .map(row)
    }

    static func row(_ play: Play) -> StatsPlayRow {
        let time = ScoutFormat.clock(play.startT)
        var title = play.type.label
        if let shape = play.zoneShape, !shape.isEmpty { title += " (\(shape))" }
        let players = play.orderedPlayers
            .map { "\(Labels.roleLabel(for: $0.role)): \($0.player.label)" }
            .joined(separator: Labels.separator)
        return StatsPlayRow(
            id: play.id, startT: play.startT, time: time, title: title, side: play.side, players: players,
            outcome: play.outcome.label, points: play.points != 0 ? String(play.points) : "",
            confidence: ScoutFormat.confidence(play.confidence),
            isLowConfidence: play.confidence < 0.5, description: play.description)
    }

    /// "12 of 78 plays".
    static func countText(shown: Int, total: Int) -> String {
        "\(shown) of \(total) plays"
    }

    /// The empty list (plays.js): nothing matches, or nothing was recognised.
    static func emptyText(totalPlays: Int) -> String {
        totalPlays > 0 ? "No plays match these filters." : noPlaysText
    }

    // MARK: Possessions

    /// Possessions in film order, with the team filter.
    static func possessionRows(_ analysis: GameAnalysis, side: TeamSide?) -> [StatsPossessionRow] {
        let playsByID = Dictionary(analysis.plays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return analysis.possessions.enumerated()
            .sorted { lhs, rhs in
                lhs.element.startT != rhs.element.startT ? lhs.element.startT < rhs.element.startT : lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { side == nil || $0.side == side }
            .map { possession in
                let offense = possession.playIDs
                    .compactMap { playsByID[$0] }
                    .filter { $0.category == .offense }
                    .map(\.type.label)
                var unique: [String] = []
                for label in offense where !unique.contains(label) { unique.append(label) }
                return StatsPossessionRow(
                    id: possession.id, startT: possession.startT, title: "Possession \(possession.id)",
                    side: possession.side, time: ScoutFormat.clock(possession.startT),
                    length: ScoutFormat.duration(possession.endT - possession.startT),
                    outcome: possession.outcome.label, points: possession.points,
                    startReason: possession.startReason.isEmpty ? nil : Labels.humanize(possession.startReason),
                    isTransition: possession.transition,
                    plays: unique.isEmpty ? nil : unique.joined(separator: ", "))
            }
    }

    /// "12 of 47 possessions".
    static func possessionCountText(shown: Int, total: Int) -> String {
        "\(shown) of \(total) possessions"
    }

    static func possessionEmptyText(total: Int) -> String {
        total > 0 ? "No possessions match these filters." : "No possessions were found in this film."
    }
}
