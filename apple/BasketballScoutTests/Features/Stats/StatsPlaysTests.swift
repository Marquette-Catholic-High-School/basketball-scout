import Foundation
import Testing
@testable import BasketballScout

/// The plays tab: play-type tables, the plays list, the possessions and seeking (06 §11, plays.js; 09 R13).
struct StatsPlaysTests {
    private func analysis() throws -> GameAnalysis {
        try Fixture.decode(GameAnalysis.self, "analysis.json")
    }

    private func zonePlay(_ id: String, side: TeamSide, shape: String?, start: Double = 1) -> Play {
        Play(id: id, type: .zoneDefense, category: .defense, side: side, startT: start, endT: start + 5, startFrame: 0, endFrame: 0,
             attrs: shape.map { ["zone_shape": .string($0)] } ?? [:])
    }

    // MARK: - Play-type tables

    @Test func summaryTablesPerTeamSortedByCount() throws {
        let blocks = StatsPlaysModel.summaryBlocks(try analysis())
        #expect(blocks.map(\.side) == [.scouted, .other])
        let scouted = try #require(blocks.first)
        #expect(scouted.offense.map(\.count) == ["9", "2", "2", "2", "2", "2", "2", "1"])
        #expect(scouted.offense.first?.title == "Fast Break")
        #expect(scouted.offense.first?.values == ["9", "38%", "10", "1.11", "5-9", "0"])
        #expect(scouted.offense[1].title == "Isolation")
        #expect(scouted.defense.map(\.title) == ["Man-to-Man Defense", "Zone Defense", "Full-Court Press"])
        #expect(scouted.defense.map(\.pointsPerPossession) == ["0.60", "1.83", "0.67"])
        #expect(StatsPlaySummaryRow.columnTitles == ["Count", "% Poss", "PTS", "PPP", "FG", "TO"])
    }

    @Test func zoneShapesGoOnTheZoneDefenseRowOnly() throws {
        let blocks = StatsPlaysModel.summaryBlocks(try analysis())
        #expect(blocks[0].defense.map(\.shapes) == [nil, "2-3 \u{00D7}5, unknown \u{00D7}1", nil])
        #expect(blocks[1].defense.map(\.shapes) == [nil, "1-3-1 \u{00D7}4", nil])
        #expect(blocks[0].offense.allSatisfy { $0.shapes == nil })
    }

    @Test func zoneShapesMostFrequentFirst() {
        let plays = [
            zonePlay("1", side: .scouted, shape: "1-3-1"), zonePlay("2", side: .scouted, shape: "2-3"),
            zonePlay("3", side: .scouted, shape: "2-3"), zonePlay("4", side: .scouted, shape: ""),
            zonePlay("5", side: .scouted, shape: nil), zonePlay("6", side: .other, shape: "3-2"),
            zonePlay("7", side: .scouted, shape: "matchup"),
        ]
        #expect(StatsPlaysModel.zoneShapes(plays, side: .scouted) == "2-3 \u{00D7}2, 1-3-1 \u{00D7}1, matchup \u{00D7}1")
        #expect(StatsPlaysModel.zoneShapes(plays, side: .other) == "3-2 \u{00D7}1")
    }

    @Test func noPlayTypesAtAll() throws {
        var analysis = try analysis()
        analysis.playSummary = analysis.playSummary.map { row in
            var row = row
            row.side = nil
            return row
        }
        #expect(StatsPlaysModel.summaryBlocks(analysis).isEmpty)
        #expect(StatsPlaysModel.noPlaysText == "No plays were recognised in this film.")
    }

    // MARK: - Individual plays

    @Test func playsAreListedByStartTimeWithTypesInOrderOfAppearance() throws {
        let sorted = StatsPlaysModel.sortedPlays(try analysis().plays)
        #expect(sorted.count == 78)
        #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $0.startT <= $1.startT })
        #expect(StatsPlaysModel.typeOptions(sorted).map(\.rawValue) == [
            "man_defense", "handoff", "isolation", "press", "putback", "zone_defense", "spot_up", "fast_break", "post_up",
            "pick_and_pop", "pick_and_roll",
        ])
    }

    @Test func filtersByTypeAndTeam() throws {
        let sorted = StatsPlaysModel.sortedPlays(try analysis().plays)
        let all = StatsPlaysModel.rows(sorted, filters: StatsPlaysFilters())
        #expect(all.count == 78)
        let zones = StatsPlaysModel.rows(sorted, filters: StatsPlaysFilters(type: .zoneDefense))
        #expect(zones.count == 10)
        let scoutedZones = StatsPlaysModel.rows(sorted, filters: StatsPlaysFilters(type: .zoneDefense, side: .scouted))
        #expect(scoutedZones.count == 6)
        #expect(StatsPlaysModel.countText(shown: scoutedZones.count, total: sorted.count) == "6 of 78 plays")
        #expect(StatsPlaysModel.emptyText(totalPlays: 78) == "No plays match these filters.")
        #expect(StatsPlaysModel.emptyText(totalPlays: 0) == "No plays were recognised in this film.")
        // A type that is gone after a re-run falls back to "All play types".
        let options = StatsPlaysModel.typeOptions(sorted)
        #expect(StatsPlaysModel.validated(StatsPlaysFilters(type: .cut), typeOptions: options).type == nil)
        #expect(StatsPlaysModel.validated(StatsPlaysFilters(type: .press), typeOptions: options).type == .press)
    }

    @Test func rowTextsAreTheWebs() throws {
        let sorted = StatsPlaysModel.sortedPlays(try analysis().plays)
        let handoff = try #require(sorted.first { $0.id == "pl_2" })
        let row = StatsPlaysModel.row(handoff)
        #expect(row.time == "0:09")
        #expect(row.title == "Dribble Handoff")
        #expect(row.players == "Ball handler: #20 Test Player 7 · Passer: #55 Test Player 10")
        #expect(row.outcome == "Missed FG")
        #expect(row.points == "")
        #expect(row.confidence == "70%")
        #expect(!row.isLowConfidence)
        #expect(row.watchLabel == "Watch play at 0:09")
        let zone = try #require(sorted.first { $0.type == .zoneDefense && $0.zoneShape == "1-3-1" })
        #expect(StatsPlaysModel.row(zone).title == "Zone Defense (1-3-1)")
        #expect(StatsPlaysModel.row(zone).players == "")
    }

    @Test func pointsAndLowConfidence() {
        let play = Play(id: "pl_9", type: .spotUp, category: .offense, side: .other, startT: 61.2, endT: 66, startFrame: 0, endFrame: 0,
                        outcome: .madeFieldGoal, points: 3, confidence: 0.4999)
        let row = StatsPlaysModel.row(play)
        #expect(row.points == "3")
        #expect(row.isLowConfidence)
        #expect(row.confidence == "50%")
        #expect(row.time == "1:01")
        let unknown = Play(id: "pl_10", type: .unknown("screen_the_screener"), category: .offense, side: nil, startT: 0, endT: 1,
                           startFrame: 0, endFrame: 0, outcome: .unknownOutcome, confidence: .nan)
        let unknownRow = StatsPlaysModel.row(unknown)
        #expect(unknownRow.title == "screen the screener")
        #expect(unknownRow.outcome == "–")
        #expect(unknownRow.confidence == "0%")
        #expect(!unknownRow.isLowConfidence)
    }

    @MainActor
    @Test func watchingAPlayStartsOneSecondBeforeItButNeverBeforeTheFilm() {
        let playback = PlaybackCoordinator()
        playback.seek(toPlayStartingAt: 9.1)
        #expect(playback.consumePendingSeek() == 9.1 - 1)
        playback.seek(toPlayStartingAt: 0.4)
        #expect(playback.consumePendingSeek() == 0)
        playback.duration = 600
        playback.seek(toEventAt: 25.566666666666666, eventID: "ev_00013")
        #expect(playback.consumePendingSeek() == 25.566666666666666 - 3)
        #expect(playback.focusedEventID == "ev_00013")
    }

    // MARK: - Possessions

    @Test func possessionsInFilmOrderWithTheirFacts() throws {
        let analysis = try analysis()
        let rows = StatsPlaysModel.possessionRows(analysis, side: nil)
        #expect(rows.count == 47)
        let first = try #require(rows.first)
        #expect(first.title == "Possession 1")
        #expect(first.side == .other)
        #expect(first.time == "0:01")
        #expect(first.length == "12 s")
        #expect(first.outcome == "Missed FG")
        #expect(first.points == 0)
        #expect(first.startReason == "jump ball")
        #expect(!first.isTransition)
        #expect(first.plays == "Dribble Handoff")
        #expect(first.watchLabel == "Watch possession at 0:01")
        let scouted = StatsPlaysModel.possessionRows(analysis, side: .scouted)
        #expect(!scouted.isEmpty)
        #expect(scouted.allSatisfy { $0.side == .scouted })
        #expect(StatsPlaysModel.possessionCountText(shown: scouted.count, total: rows.count) == "\(scouted.count) of 47 possessions")
        #expect(StatsPlaysModel.possessionEmptyText(total: 0) == "No possessions were found in this film.")
        #expect(StatsPlaysModel.possessionEmptyText(total: 3) == "No possessions match these filters.")
    }

    @Test func possessionOutcomes() {
        #expect(PossessionOutcome.madeFieldGoal.label == "Made FG")
        #expect(PossessionOutcome.missedFieldGoal.label == "Missed FG")
        #expect(PossessionOutcome.turnover.label == "Turnover")
        #expect(PossessionOutcome.foul.label == "Foul")
        #expect(PossessionOutcome.freeThrows.label == "Free throws")
        #expect(PossessionOutcome.endOfPeriod.label == "End of period")
        #expect(PossessionOutcome.unknownOutcome.label == "–")
        #expect(PossessionOutcome.unknown("shot_clock").label == "Shot clock")
    }

    @MainActor
    @Test func playsFiltersAreRememberedPerGame() {
        let memory = StatsMemory(defaults: UserDefaults(suiteName: "StatsPlaysTests.\(UUID().uuidString)") ?? .standard)
        #expect(memory.playsFilters(for: "g_1") == StatsPlaysFilters())
        let filters = StatsPlaysFilters(list: .possessions, type: .press, side: .other, possessionSide: .scouted)
        memory.setPlaysFilters(filters, for: "g_1")
        #expect(memory.playsFilters(for: "g_1") == filters)
        #expect(memory.playsFilters(for: "g_2") == StatsPlaysFilters())
        memory.setBoxScore(StatsBoxScoreMemory(side: .other, sort: StatsBoxScoreSort(column: .points, ascending: false)), for: "g_1")
        #expect(memory.boxScore(for: "g_1").side == .other)
        #expect(memory.boxScore(for: "g_2") == StatsBoxScoreMemory())
    }
}
