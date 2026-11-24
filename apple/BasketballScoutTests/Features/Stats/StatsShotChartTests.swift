import Foundation
import Testing
@testable import BasketballScout

/// The shot chart's filters, zone numbers, notes and texts (06 §10, shotchart.js; 09 R46).
struct StatsShotChartTests {
    private func analysis() throws -> GameAnalysis {
        try Fixture.decode(GameAnalysis.self, "analysis.json")
    }

    private func teamName(_ side: TeamSide) -> String {
        side == .scouted ? "Test Team A" : "Test Team B"
    }

    private func model(_ analysis: GameAnalysis, _ filters: StatsShotFilters = StatsShotFilters()) -> StatsShotChartModel {
        StatsShotChartModel(analysis: analysis, filters: filters, teamName: teamName)
    }

    private func shot(_ id: String, side: TeamSide = .scouted, made: Bool = true, zone: ShotZone = .paint, at xy: XY? = XY(x: 6, y: 25),
                      t: Double = 10, player: PlayerRef? = nil) -> ShotRecord {
        ShotRecord(eventID: id, t: t, side: side, player: player, made: made, points: made ? 2 : 0, isThree: false, zone: zone, halfCourtXY: xy)
    }

    private func player(_ number: Int, jersey: String?, side: TeamSide = .scouted, id: Bool = true) -> PlayerRef {
        PlayerRef(playerID: id ? "p_test\(number)" : nil, jersey: jersey, name: "Test Player \(number)", side: side, matchConfidence: 0.9)
    }

    // MARK: - Filters

    @Test func theScoutedTeamIsTheDefault() throws {
        let model = model(try analysis())
        #expect(model.filters.team == .scouted)
        #expect(model.pool.count == 23)
        #expect(model.visible.count == 23)
        #expect(model.drawn.count == 23)
        #expect(model.pool.allSatisfy { $0.side == .scouted })
        #expect(model.note == nil)
    }

    @Test func bothTeamsShowsEveryShot() throws {
        let model = model(try analysis(), StatsShotFilters(team: .both))
        #expect(model.pool.count == 47)
        #expect(model.drawn.filter(\.made).count == 21)
    }

    @Test func theResultFilterChangesTheMarksButNotTheZoneNumbers() throws {
        let analysis = try analysis()
        let all = model(analysis)
        let made = model(analysis, StatsShotFilters(result: .made))
        let missed = model(analysis, StatsShotFilters(result: .missed))
        #expect(made.drawn.count == 11)
        #expect(made.drawn.allSatisfy { $0.made })
        #expect(missed.drawn.count == 12)
        #expect(made.tallies == all.tallies)
        #expect(made.zoneRows == all.zoneRows)
        #expect(StatsShotResultFilter.allCases.map(\.title) == ["Made and missed", "Made only", "Missed only"])
    }

    @Test func thePlayerFilterNarrowsThePool() throws {
        let analysis = try analysis()
        let key = "scouted|p_fixture02"
        let model = model(analysis, StatsShotFilters(playerKey: key))
        #expect(model.filters.playerKey == key)
        #expect(!model.pool.isEmpty)
        #expect(model.pool.allSatisfy { $0.player?.jersey == "5" })
        #expect(model.tally(.paint).attempts + model.tally(.three).attempts == model.pool.count)
    }

    @Test func aPlayerOfTheOtherTeamFallsBackToAllPlayers() throws {
        // shotchart.js buildPlayerOptions: a choice that is not among the team's shooters resets to "All players".
        let model = model(try analysis(), StatsShotFilters(team: .other, playerKey: "scouted|p_fixture02"))
        #expect(model.filters.playerKey == nil)
        #expect(model.pool.count == 24)
    }

    @Test func playerChoicesAreInJerseyOrderWithZeroBeforeDoubleZero() {
        let shots = [
            shot("a", player: player(1, jersey: "12")), shot("b", player: player(2, jersey: "00")),
            shot("c", player: player(3, jersey: "0")), shot("d", player: player(4, jersey: nil, id: false)),
            shot("e", player: player(1, jersey: "12")), shot("f", player: nil),
        ]
        let options = StatsShotChartModel.playerOptions(shots, includeTeam: false, teamName: teamName)
        #expect(options.map(\.title) == ["#0 Test Player 3", "#00 Test Player 2", "#12 Test Player 1", "Test Player 4"])
        #expect(options.map(\.key) == ["scouted|p_test3", "scouted|p_test2", "scouted|p_test1", "scouted|Test Player 4"])
    }

    @Test func withBothTeamsChoicesNameTheTeam() throws {
        let model = model(try analysis(), StatsShotFilters(team: .both))
        #expect(model.playerOptions.contains { $0.title == "#5 Test Player 2 (Test Team A)" })
        #expect(model.playerOptions.contains { $0.title.hasSuffix("(Test Team B)") })
        let scouted = self.model(try analysis())
        #expect(scouted.playerOptions.map(\.title) == ["#0 Test Player 1", "#5 Test Player 2", "#11 Test Player 3", "#14 Test Player 4", "#33 Test Player 5"])
    }

    @Test func playerKeysFollowTheTimelineRule() {
        #expect(StatsShotChartModel.playerKey(player(7, jersey: "3", side: .other)) == "other|p_test7")
        #expect(StatsShotChartModel.playerKey(PlayerRef(jersey: "3", side: .other)) == "other|#3")
        #expect(StatsShotChartModel.playerKey(PlayerRef(playerID: "", jersey: "3")) == "|#3")
        #expect(StatsShotChartModel.playerKey(nil) == "")
    }

    // MARK: - Periods

    @Test func periodsComeFromTheTimeline() throws {
        let analysis = try analysis()
        let periods = StatsPeriod.periods(in: analysis.timeline)
        #expect(periods.map(\.number) == [1, 2])
        #expect(periods.map(\.title) == ["Period 1", "Period 2"])
        #expect(StatsPeriod.number(at: 0.2, in: periods) == 1)
        #expect(StatsPeriod.number(at: 299, in: periods) == 1)
        #expect(StatsPeriod.number(at: 300.3, in: periods) == 2)
        #expect(StatsPeriod.number(at: .nan, in: periods) == nil)
        #expect(StatsPeriod.number(at: 10, in: []) == nil)
        let second = model(analysis, StatsShotFilters(period: 2))
        #expect(second.filters.period == 2)
        #expect(second.pool.count == 12)
        #expect(second.pool.allSatisfy { $0.t >= 300.3 })
    }

    @Test func periodNumbersComeFromTheLabelsOrAreCounted() {
        let labelled = [
            TimelineEvent(id: "p3", t: 5, frame: 150, type: .periodStart, label: "Start of Period 3"),
            TimelineEvent(id: "p4", t: 400, frame: 12000, type: .periodStart, label: "Start of Period 4"),
        ]
        #expect(StatsPeriod.periods(in: labelled).map(\.number) == [3, 4])
        let unnumbered = [
            TimelineEvent(id: "b", t: 400, frame: 12000, type: .periodStart, label: "Start of Period"),
            TimelineEvent(id: "a", t: 5, frame: 150, type: .periodStart, label: "Start of Period"),
            TimelineEvent(id: "c", t: 200, frame: 6000, type: .periodEnd, label: "End of Period"),
        ]
        #expect(StatsPeriod.periods(in: unnumbered).map(\.number) == [1, 2])
        #expect(StatsPeriod.periods(in: unnumbered).map(\.startT) == [5, 400])
    }

    @Test func aPeriodThatNoLongerExistsFallsBackToAllPeriods() throws {
        let model = model(try analysis(), StatsShotFilters(period: 7))
        #expect(model.filters.period == nil)
        #expect(model.pool.count == 23)
    }

    // MARK: - Zones

    @Test func zoneTalliesPutUnknownZonesTogether() {
        var analysis = StatsAnalysisStub.empty
        analysis.shots = [
            shot("1", zone: .paint), shot("2", made: false, zone: .paint), shot("3", zone: .three),
            shot("4", made: false, zone: .unknownZone, at: nil), shot("5", zone: .unknown("backcourt")),
        ]
        let model = model(analysis)
        #expect(model.tally(.paint) == StatsZoneTally(made: 1, attempts: 2))
        #expect(model.tally(.mid) == StatsZoneTally())
        #expect(model.tally(.three) == StatsZoneTally(made: 1, attempts: 1))
        #expect(model.tally(.unknownZone) == StatsZoneTally(made: 1, attempts: 2))
    }

    @Test func zoneLabelsOnTheCourt() throws {
        let model = model(try analysis())
        #expect(model.zoneLabel(.paint) == "Paint 8/16 · 50%")
        #expect(model.zoneLabel(.mid) == "Mid-range 0/0")
        #expect(model.zoneLabel(.three) == "3-point 3/7 · 43%")
    }

    @Test func theByZoneTable() throws {
        let rows = model(try analysis()).zoneRows
        #expect(rows.map(\.title) == ["Paint", "Mid-range", "3-point", "Unknown zone", "All shots"])
        #expect(rows.map(\.fieldGoals) == ["8-16", "0-0", "3-7", "0-0", "11-23"])
        #expect(rows.map(\.percent) == ["50.0%", "–", "42.9%", "–", "47.8%"])
        #expect(rows.map(\.share) == ["70%", "0%", "30%", "0%", "100%"])
        #expect(rows.map(\.isTotal) == [false, false, false, false, true])
        let empty = model(StatsAnalysisStub.empty).zoneRows
        #expect(empty.map(\.share) == ["–", "–", "–", "–", "–"])
        #expect(empty.last?.fieldGoals == "0-0")
    }

    // MARK: - Notes and texts

    @Test func notesUnderTheChart() {
        var analysis = StatsAnalysisStub.empty
        #expect(model(analysis).note == .noShots)
        analysis.shots = [shot("1", at: nil), shot("2", at: nil)]
        #expect(model(analysis).note == .noLocations)
        analysis.shots = [shot("1", at: nil), shot("2"), shot("3", made: false, at: XY(x: .nan, y: .nan))]
        #expect(model(analysis).note == .notDrawn(2))
        #expect(model(analysis).drawn.map(\.eventID) == ["2"])
        analysis.shots = [shot("1"), shot("2", made: false, at: nil)]
        #expect(model(analysis, StatsShotFilters(result: .made)).note == nil)
        #expect(model(analysis).note == .notDrawn(1))
        #expect(StatsShotNote.notDrawnText(1) == "1 shot without a court location is not drawn.")
        #expect(StatsShotNote.notDrawnText(3) == "3 shots without a court location are not drawn.")
        #expect(StatsShotNote.noShotsText == "No shots were detected in this film.")
        #expect(StatsShotNote.noLocationsMessage == "The court wasn't mapped in this film, so shots can't be placed on the chart.")
    }

    @Test func detailsOfAShot() throws {
        let first = try #require(try analysis().shots.first { $0.side == .scouted })
        #expect(StatsShotChartModel.detailText(for: first) == "#5 Test Player 2 · 2PT make · 0:25 · paint")
        let three = ShotRecord(
            eventID: "x", t: 75.9, side: .other, player: nil, made: false, points: 0, isThree: true, zone: .three,
            subzone: "left_wing_3", assisted: false, blocked: true)
        #expect(StatsShotChartModel.detailText(for: three) == "Unknown player · 3PT miss · 1:15 · left wing 3 · blocked")
        let unknownThree = ShotRecord(eventID: "y", t: 3, side: .other, made: true, points: 2, isThree: nil, zone: .unknownZone, assisted: true)
        #expect(StatsShotChartModel.detailText(for: unknownThree) == "Unknown player · 2PT make · 0:03 · Unknown · assisted")
        let spoken = StatsShotChartModel.spokenText(for: three)
        #expect(spoken.hasPrefix("Unknown player, 3-point miss, "))
        #expect(spoken.hasSuffix(", left wing 3, blocked"))
    }

    @Test func theChartsSummary() throws {
        #expect(model(try analysis()).accessibilitySummary == "Shot chart: 23 shots drawn, 11 made. The zone table lists the same numbers.")
    }

    // MARK: - Remembered choices (09 R46)

    @MainActor
    @Test func theTeamChoiceIsKeptAcrossReloadsAndGames() throws {
        let suite = "StatsShotChartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = StatsMemory(defaults: defaults)
        #expect(memory.shotFilters(for: "g_1").team == .scouted)
        var filters = memory.shotFilters(for: "g_1")
        filters.team = .both
        filters.result = .missed
        memory.setShotFilters(filters, for: "g_1")
        #expect(memory.shotFilters(for: "g_1") == filters)
        // Another game and a new app run keep the team; the other filters belong to the game.
        #expect(memory.shotFilters(for: "g_2").team == .both)
        #expect(memory.shotFilters(for: "g_2").result == .all)
        #expect(StatsMemory(defaults: defaults).shotFilters(for: "g_1").team == .both)
        #expect(defaults.string(forKey: StatsShotTeamChoice.storageKey) == "both")
    }

    @MainActor
    @Test func showShotsFromTheBoxScore() throws {
        let suite = "StatsShotChartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = StatsMemory(defaults: defaults)
        memory.setShotFilters(StatsShotFilters(team: .scouted, period: 2, result: .made, playerKey: nil), for: "g_1")
        memory.showShots(of: "other|p_test7", side: .other, gameID: "g_1")
        #expect(memory.shotFilters(for: "g_1") == StatsShotFilters(team: .other, period: nil, result: .all, playerKey: "other|p_test7"))
    }
}

/// An analysis with nothing in it, to build the stats tests' cases from.
nonisolated enum StatsAnalysisStub {
    static var empty: GameAnalysis {
        GameAnalysis(
            schemaVersion: "1.0", gameID: "g_000000000001", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            video: VideoInfo(filename: "", fps: 30, width: 1920, height: 1080, frameCount: 0, durationS: 0, analysisFPS: 10, codec: nil),
            pipeline: PipelineInfo(name: "synthetic", version: "1.0", models: [:], gpu: nil, elapsedS: nil, options: [:]),
            teams: [], timeline: [], possessions: [], plays: [], shots: [], boxScores: [], playSummary: [], trackAssignments: [],
            dataQuality: DataQuality())
    }
}
