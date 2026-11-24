import Foundation
import Testing
@testable import BasketballScout

/// The box score tab's rows, texts and sorting (06 §9, boxscore.js; 09 R46).
struct StatsBoxScoreTests {
    private func analysis(_ name: String = "analysis.json") throws -> GameAnalysis {
        try Fixture.decode(GameAnalysis.self, name)
    }

    private func model(_ side: TeamSide = .scouted, fixture: String = "analysis.json") throws -> StatsBoxScoreModel {
        StatsBoxScoreModel(box: try #require(try analysis(fixture).boxScore(side)))
    }

    /// A player line with only what the test needs.
    private func line(jersey: String?, name: String? = nil, pts: Int = 0, fgm: Int = 0, fga: Int = 0, minutes: Double? = 10,
                      plusMinus: Int? = nil) -> BoxScoreLine {
        BoxScoreLine(player: PlayerRef(jersey: jersey, name: name, side: .scouted), minutesEst: minutes, pts: pts, fgm: fgm, fga: fga,
                     plusMinus: plusMinus)
    }

    private func rows(_ lines: [BoxScoreLine]) -> [StatsBoxScoreRow] {
        lines.enumerated().map { StatsBoxScoreRow(id: "scouted:\($0.offset)", kind: .player, line: $0.element, order: $0.offset) }
    }

    // MARK: - Rows and texts

    @Test func rowsKeepTheServerOrderThenTheTeamLineAndTheTotals() throws {
        let model = try model()
        let rows = model.rows(sortedBy: .serverOrder)
        #expect(rows.map(\.jersey) == ["0", "5", "11", "14", "33", "", ""])
        #expect(rows.map(\.name).suffix(2) == ["Team / unidentified", "Totals"])
        #expect(rows.map(\.kind).suffix(2) == [.team, .totals])
        #expect(rows.first?.name == "Test Player 1")
        #expect(rows.first?.title == "#0 Test Player 1")
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func playerCellsAreTheWebsTexts() throws {
        let row = try #require(try model().playerRows.first { $0.jersey == "5" })
        let texts = StatsBoxScoreColumn.allCases.map { row.text($0) }
        #expect(texts == ["5", "Test Player 2", "10.0", "12", "6-13", "46.2%", "0-4", "0.0%", "0-0", "–", "0", "0", "0", "0", "1", "0", "0", "1", "-2"])
    }

    @Test func teamAndTotalsCells() throws {
        let model = try model()
        #expect(model.teamRow.text(.jersey) == "")
        #expect(model.teamRow.text(.player) == "Team / unidentified")
        #expect(model.teamRow.text(.minutes) == "–")
        #expect(model.teamRow.text(.plusMinus) == "–")
        #expect(!model.teamRow.isDNP)
        let totals = StatsBoxScoreColumn.allCases.map { model.totalsRow.text($0) }
        #expect(totals == ["", "Totals", "–", "25", "11-23", "47.8%", "3-7", "42.9%", "0-0", "–", "2", "11", "13", "7", "1", "1", "1", "3", "–"])
    }

    @Test func percentagesRoundExactlyLikeTheWeb() {
        // JavaScript (f × 100).toFixed(1): binary ties go away from zero, everything else to the nearest.
        let cases: [(Double?, String)] = [(0.0625, "6.3%"), (0.125, "12.5%"), (0.462, "46.2%"), (0.4, "40.0%"), (1, "100.0%"), (0, "0.0%"), (nil, "–")]
        for (value, expected) in cases {
            var line = line(jersey: "1")
            line.fgPct = value
            let row = StatsBoxScoreRow(id: "x", kind: .player, line: line, order: 0)
            #expect(row.text(.fieldGoalPercent) == expected, "\(String(describing: value))")
        }
    }

    @Test func plusMinusIsSigned() {
        let texts = [3, 0, -2, nil].map { value -> String in
            StatsBoxScoreRow(id: "x", kind: .player, line: line(jersey: "1", plusMinus: value), order: 0).text(.plusMinus)
        }
        #expect(texts == ["+3", "0", "-2", "–"])
    }

    @Test func playersWhoDidNotPlayAreMarked() throws {
        let model = try model(fixture: "analysis_unmatched.json")
        let dnp = model.playerRows.filter(\.isDNP)
        #expect(dnp.map(\.jersey) == ["1", "02", "4"])
        #expect(dnp.allSatisfy { $0.text(.minutes) == "DNP" })
        #expect(model.playerRows.first { $0.jersey == "0" }?.text(.minutes) == "10.0")
        // The team and totals lines are never DNP, even with nothing on them.
        let empty = StatsBoxScoreRow(id: "t", kind: .team, line: line(jersey: nil, minutes: nil), order: 0)
        #expect(!empty.isDNP)
        #expect(empty.text(.minutes) == "–")
    }

    @Test func unnamedPlayersUseTheirLabel() throws {
        let model = try model(fixture: "analysis_unmatched.json")
        let row = try #require(model.playerRows.first { $0.jersey == "0" })
        #expect(row.name == "#0")
        #expect(row.title == "#0")
    }

    @Test func spokenCellsReadWell() throws {
        let row = try #require(try model().playerRows.first { $0.jersey == "5" })
        #expect(row.spokenText(.fieldGoals) == "6 of 13")
        #expect(row.spokenText(.freeThrowPercent) == "none")
        #expect(row.spokenText(.jersey) == "number 5")
        let dnp = try #require(try model(fixture: "analysis_unmatched.json").playerRows.first(where: \.isDNP))
        #expect(dnp.spokenText(.minutes) == "Did not play")
    }

    // MARK: - Sorting (boxscore.js sortBy / sortLines)

    @Test func firstClicksAndToggles() {
        var sort = StatsBoxScoreSort.serverOrder
        #expect(sort.column == nil)
        sort.select(.points)
        #expect(sort == StatsBoxScoreSort(column: .points, ascending: false))
        sort.select(.points)
        #expect(sort == StatsBoxScoreSort(column: .points, ascending: true))
        sort.select(.player)
        #expect(sort == StatsBoxScoreSort(column: .player, ascending: true))
        sort.select(.jersey)
        #expect(sort == StatsBoxScoreSort(column: .jersey, ascending: true))
        sort.select(.jersey)
        #expect(sort == StatsBoxScoreSort(column: .jersey, ascending: false))
        #expect(StatsBoxScoreSort.serverOrder.selecting(.minutes) == StatsBoxScoreSort(column: .minutes, ascending: false))
        #expect(StatsBoxScoreColumn.allCases.filter(\.firstSortAscending) == [.jersey, .player])
    }

    @Test func jerseysSortByNumberWithZeroBeforeDoubleZero() {
        let rows = rows(["10", "00", "5", "0", "05", nil, "1"].map { line(jersey: $0) })
        let ascending = StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .jersey, ascending: true))
        #expect(ascending.map(\.jersey) == ["0", "00", "1", "5", "05", "10", ""])
        let descending = StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .jersey, ascending: false))
        #expect(descending.map(\.jersey) == ["", "10", "05", "5", "1", "00", "0"])
    }

    @Test func equalValuesKeepTheServerOrder() throws {
        let model = try model()
        // Everyone is -2: a stable sort changes nothing, in either direction.
        let byPlusMinus = model.rows(sortedBy: StatsBoxScoreSort(column: .plusMinus, ascending: false))
        #expect(byPlusMinus.map(\.jersey) == ["0", "5", "11", "14", "33", "", ""])
        let byPoints = model.rows(sortedBy: StatsBoxScoreSort(column: .points, ascending: false))
        #expect(byPoints.map(\.jersey) == ["5", "33", "11", "0", "14", "", ""])
        #expect(byPoints.suffix(2).map(\.kind) == [.team, .totals])
    }

    @Test func missingValuesSortLikeTheWeb() {
        var noShots = line(jersey: "1", plusMinus: nil)
        noShots.fgPct = nil
        var cold = line(jersey: "2", plusMinus: -5)
        cold.fgPct = 0
        var hot = line(jersey: "3", plusMinus: 4)
        hot.fgPct = 0.5
        let rows = rows([noShots, cold, hot])
        // FG% missing counts as -1 (after 0 %), plus-minus missing as -∞.
        #expect(StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .fieldGoalPercent, ascending: false)).map(\.jersey) == ["3", "2", "1"])
        #expect(StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .plusMinus, ascending: true)).map(\.jersey) == ["1", "2", "3"])
        let minutes = self.rows([line(jersey: "1", minutes: nil), line(jersey: "2", minutes: 0), line(jersey: "3", minutes: 0.4)])
        #expect(StatsBoxScoreModel.sorted(minutes, by: StatsBoxScoreSort(column: .minutes, ascending: false)).map(\.jersey) == ["3", "2", "1"])
    }

    @Test func namesSortAsLowerCasedTextInLocaleOrder() {
        let rows = rows([
            line(jersey: "1", name: "Test Player 10"), line(jersey: "2", name: "test player 2"),
            line(jersey: "3", name: "Test Player 1"), line(jersey: "14"),
        ])
        let sorted = StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .player, ascending: true), locale: Locale(identifier: "en_US"))
        #expect(sorted.map(\.name) == ["#14", "Test Player 1", "Test Player 10", "test player 2"])
    }

    @Test func madeAttemptedColumnsSortByMakes() {
        let rows = rows([line(jersey: "1", fgm: 2, fga: 10), line(jersey: "2", fgm: 5, fga: 6), line(jersey: "3", fgm: 3, fga: 3)])
        #expect(StatsBoxScoreModel.sorted(rows, by: StatsBoxScoreSort(column: .fieldGoals, ascending: false)).map(\.jersey) == ["2", "3", "1"])
    }

    @Test func theTableComparatorAgreesWithTheModel() {
        let rows = rows([line(jersey: "1", pts: 4), line(jersey: "2", pts: 9)])
        let comparator = StatsBoxScoreComparator(column: .points, order: .reverse)
        #expect(comparator.compare(rows[0], rows[1]) == .orderedDescending)
        #expect(StatsBoxScoreComparator(column: .points, order: .forward).compare(rows[0], rows[1]) == .orderedAscending)
    }

    // MARK: - Summary, zones, team, copy

    @Test func summaryLine() throws {
        #expect(try model().summary.map { "\($0.label): \($0.value)" } == ["Points: 25", "Possessions: 24", "Points per possession: 1.04"])
        #expect(try model(.other).summary.map(\.value) == ["27", "23", "1.17"])
        #expect(try model().caption == "Test Team A box score")
    }

    @Test func shootingByZoneLeavesOutPlayersWhoDidNotPlay() throws {
        let model = try model(fixture: "analysis_unmatched.json")
        let rows = model.zoneRows
        #expect(rows.map(\.name) == ["#0", "#5", "#11", "#14", "#23", "Team / unidentified", "Totals"])
        let totals = try #require(rows.last)
        #expect(StatsBoxScoreZoneRow.zones.map { totals.text($0) } == ["8-16 (50%)", "–", "3-7 (43%)", "–"])
        #expect(StatsBoxScoreZoneRow.zones.map(\.boxScoreColumnLabel) == ["Paint", "Mid-range", "3-point", "No location"])
        #expect(totals.spokenText(.paint) == "8 of 16, 50%")
        #expect(totals.spokenText(.mid) == "none")
    }

    @Test func theScoutedTeamIsShownUnlessTheAnalysisLacksIt() throws {
        var analysis = try analysis()
        #expect(StatsBoxScoreModel.side(in: analysis, preferred: .scouted) == .scouted)
        #expect(StatsBoxScoreModel.side(in: analysis, preferred: .other) == .other)
        analysis.boxScores.removeFirst()
        #expect(StatsBoxScoreModel.side(in: analysis, preferred: .scouted) == .other)
        analysis.boxScores = []
        #expect(StatsBoxScoreModel.side(in: analysis, preferred: .scouted) == nil)
    }

    @Test func emptyAndHintTexts() throws {
        #expect(StatsBoxScoreModel.emptyPlayersMessage == "No identified players yet - match jerseys on the roster page.")
        #expect(StatsBoxScoreModel.noBoxScoreMessage == "No box score in this analysis.")
        var box = try #require(try analysis().boxScore(.scouted))
        box.players = []
        #expect(!StatsBoxScoreModel(box: box).hasPlayers)
        #expect(StatsBoxScoreModel(box: box).rows(sortedBy: .serverOrder).map(\.kind) == [.team, .totals])
        #expect(StatsBoxScoreColumn.minutes.help == "Approximate on-floor video minutes")
        #expect(StatsBoxScoreColumn.allCases.map(\.title) == [
            "#", "Player", "MIN", "PTS", "FG", "FG%", "3PT", "3P%", "FT", "FT%", "OREB", "DREB", "REB", "AST", "STL", "BLK", "TO", "PF", "+/-",
        ])
    }

    @Test func copiedRowsAreTabSeparatedWithAHeader() throws {
        let model = try model()
        let text = StatsBoxScoreModel.tabSeparated([model.playerRows[1], model.totalsRow])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("#\tPlayer\tMIN\tPTS\tFG\tFG%"))
        #expect(lines[1].hasPrefix("5\tTest Player 2\t10.0\t12\t6-13\t46.2%"))
        #expect(lines[2].hasPrefix("\tTotals\t–\t25\t11-23"))
    }

    @Test func playerRowsLinkToTheShotChart() throws {
        let model = try model()
        #expect(model.playerRows[1].shotChartPlayerKey == "scouted|p_fixture02")
        #expect(model.teamRow.shotChartPlayerKey == nil)
        #expect(model.totalsRow.shotChartPlayerKey == nil)
    }
}
