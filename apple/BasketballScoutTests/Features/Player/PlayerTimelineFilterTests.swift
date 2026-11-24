import Foundation
import Testing
@testable import BasketballScout

/// The event timeline's data: order, filters, picker options, search and row texts (06 §8;
/// timeline.js:79-232). Fixture counts come from a port of the web's code run on `analysis.json`.
struct PlayerTimelineFilterTests {
    private static let names = PlayerTeamNames(scouted: "Test Team A", other: "Test Team B")

    private static func fixtureIndex() throws -> PlayerTimelineIndex {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        return PlayerTimelineIndex(analysis: analysis, gameID: analysis.gameID, teamNames: names)
    }

    private static func count(_ filter: PlayerTimelineFilter, _ index: PlayerTimelineIndex) -> Int {
        filter.apply(to: index).count
    }

    // MARK: - The fixture, against the web

    @Test func rowsAreInFilmOrder() throws {
        let index = try Self.fixtureIndex()
        #expect(index.events.count == 310)
        #expect(index.haystacks.count == 310)
        #expect(zip(index.events, index.events.dropFirst()).allSatisfy { $0.t < $1.t || ($0.t == $1.t && $0.frame <= $1.frame) })
        #expect(index.analysisDuration == 600)
        #expect(index.possessions.count == 47)
    }

    @Test func teamTypeAndPlayFiltersMatchTheWeb() throws {
        let index = try Self.fixtureIndex()
        #expect(Self.count(PlayerTimelineFilter(), index) == 310)
        #expect(Self.count(PlayerTimelineFilter(team: .scouted), index) == 148)
        #expect(Self.count(PlayerTimelineFilter(team: .other), index) == 158)  // the 4 rows without a team are hidden
        #expect(Self.count(PlayerTimelineFilter(types: [.shotMade, .shotMissed]), index) == 47)
        #expect(Self.count(PlayerTimelineFilter(play: .anyPlay), index) == 120)
        #expect(Self.count(PlayerTimelineFilter(play: .type(.fastBreak)), index) == 55)
        #expect(Self.count(PlayerTimelineFilter(play: .type(.pickAndRoll)), index) == 12)
        #expect(Self.count(PlayerTimelineFilter(play: .type(.zoneDefense)), index) == 0)
        // Filters combine with AND.
        let both = PlayerTimelineFilter(team: .scouted, types: [.shotMade])
        #expect(Self.count(both, index) == index.events.filter { $0.side == .scouted && $0.type == .shotMade }.count)
    }

    @Test func searchMatchesTheWeb() throws {
        let index = try Self.fixtureIndex()
        func search(_ text: String) -> Int { Self.count(PlayerTimelineFilter(search: text), index) }
        #expect(search("corner") == 4)
        #expect(search("assist") == 28)
        #expect(search("pick & roll") == 12)  // the covering play's type
        #expect(search("#42") == 103)
        #expect(search("paint") == 31)  // the zone text too
        #expect(search("  PAINT \n") == 31)  // trimmed, any case
        #expect(search("no such words") == 0)
    }

    @Test func playerFilterMatchesThePlayerOrTheSecondPlayer() throws {
        let index = try Self.fixtureIndex()
        #expect(index.playerOptions.count == 10)
        let option = try #require(index.playerOptions.first { $0.label == "#42 Test Player 9" })
        let expected = index.events.filter {
            PlayerTimelinePlayerOption.key(for: $0.player) == option.key || PlayerTimelinePlayerOption.key(for: $0.secondaryPlayer) == option.key
        }.count
        #expect(expected > 0)
        #expect(Self.count(PlayerTimelineFilter(playerKey: option.key), index) == expected)
    }

    @Test func filterOptionsComeFromTheRows() throws {
        let index = try Self.fixtureIndex()
        // Types present, in the web's filter order (labels.js:5-24).
        #expect(index.typeOptions == [
            .shotMade, .shotMissed, .freeThrowMade, .freeThrowMissed, .offensiveRebound, .defensiveRebound, .assist, .steal,
            .block, .turnover, .foul, .screen, .pass, .jumpBall, .periodStart, .periodEnd, .possessionChange,
        ])
        #expect(index.playTypeOptions == [.pickAndRoll, .pickAndPop, .isolation, .fastBreak, .postUp, .handoff, .spotUp, .putback])
    }

    // MARK: - Player picker (timeline.js:116-130, fixed per 09 R46)

    private static func ref(_ jersey: String?, _ number: Int, _ side: TeamSide?, id: String? = nil) -> PlayerRef {
        PlayerRef(playerID: id ?? "p_test\(number)", jersey: jersey, name: "Test Player \(number)", side: side)
    }

    @Test func playersAreListedScoutedFirstThenByNumberWithZeroBeforeDoubleZero() {
        let refs = [
            Self.ref("12", 1, .other), Self.ref("00", 2, .scouted), Self.ref("5", 3, .scouted), Self.ref(nil, 4, .scouted),
            Self.ref("0", 5, .scouted), Self.ref("05", 6, .scouted), Self.ref("3", 7, nil), Self.ref("1", 8, .other),
        ]
        let events = refs.enumerated().map { offset, ref in
            TimelineEvent(id: "ev_\(offset)", t: Double(offset), frame: offset, type: .shotMade, label: "2PT Make", side: ref.side, player: ref)
        }
        let options = PlayerTimelinePlayerOption.options(from: events)
        #expect(options.map(\.label) == [
            "#0 Test Player 5", "#00 Test Player 2", "#5 Test Player 3", "#05 Test Player 6", "Test Player 4",
            "#1 Test Player 8", "#12 Test Player 1",
            "#3 Test Player 7",
        ])
        #expect(options[0].title(teamNames: Self.names) == "#0 Test Player 5 (Test Team A)")
        #expect(options[5].title(teamNames: Self.names) == "#1 Test Player 8 (Test Team B)")
        #expect(options.last?.title(teamNames: Self.names) == "#3 Test Player 7")
    }

    @Test func playerKeysUseTheRosterIdElseTheLabel() {
        #expect(PlayerTimelinePlayerOption.key(for: Self.ref("3", 1, .scouted, id: "p_abc")) == "scouted|p_abc")
        let unmatched = PlayerRef(playerID: nil, jersey: "3", name: nil, side: .other)
        #expect(PlayerTimelinePlayerOption.key(for: unmatched) == "other|#3")
        let empty = PlayerRef(playerID: "", jersey: nil, name: nil, side: nil)
        #expect(PlayerTimelinePlayerOption.key(for: empty) == "|Unknown player")
        #expect(PlayerTimelinePlayerOption.key(for: nil) == nil)
        // The first reference names a player once, whether primary or secondary.
        let assist = TimelineEvent(
            id: "ev_1", t: 1, frame: 30, type: .assist, label: "Assist", side: .scouted,
            player: Self.ref("3", 1, .scouted), secondaryPlayer: Self.ref("12", 2, .scouted))
        let shot = TimelineEvent(
            id: "ev_2", t: 1, frame: 30, type: .shotMade, label: "2PT Make", side: .scouted,
            player: Self.ref("12", 2, .scouted), secondaryPlayer: Self.ref("3", 1, .scouted))
        #expect(PlayerTimelinePlayerOption.options(from: [assist, shot]).count == 2)
    }

    // MARK: - Reloads and summaries

    @Test func choicesThatNoLongerExistAreDroppedTheRestSurvive() throws {
        let index = try Self.fixtureIndex()
        var filter = PlayerTimelineFilter(
            team: .other, types: [.shotMade, .unknown("dunk")], playerKey: "scouted|p_gone", play: .type(.zoneDefense), search: "paint")
        filter = filter.pruned(for: index)
        #expect(filter.team == .other)
        #expect(filter.types == [.shotMade])
        #expect(filter.playerKey == nil)
        #expect(filter.play == nil)
        #expect(filter.search == "paint")

        let kept = PlayerTimelineFilter(play: .anyPlay).pruned(for: index)
        #expect(kept.play == .anyPlay)
        #expect(PlayerTimelineFilter(play: .anyPlay).pruned(for: .empty).play == nil)
    }

    @Test func summariesUseTheWebsWords() {
        #expect(PlayerTimelineFilter().typesSummary == "All event types")
        #expect(PlayerTimelineFilter(types: [.foul]).typesSummary == "1 event type")
        #expect(PlayerTimelineFilter(types: [.foul, .steal, .block]).typesSummary == "3 event types")
        #expect(PlayerText.count(shown: 12, total: 310) == "12 of 310 events")
        #expect(!PlayerTimelineFilter().isActive)
        #expect(!PlayerTimelineFilter(search: "   ").isActive)
        #expect(PlayerTimelineFilter(search: "a").isActive)
        #expect(PlayerTimelineFilter(play: .anyPlay).isActive)
    }

    @Test func anAnalysisWithoutEventsGivesAnEmptyIndex() throws {
        var analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        analysis.timeline = []
        let index = PlayerTimelineIndex(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        #expect(index.isEmpty)
        #expect(index.typeOptions.isEmpty && index.playerOptions.isEmpty && index.playTypeOptions.isEmpty)
        #expect(PlayerTimelineIndex.empty.identity == nil)
        #expect(index.identity?.eventCount == 0)
    }

    // MARK: - Row texts (timeline.js:206-232)

    @Test func theSecondLineNamesThePlayersAndTheZone() {
        var shot = TimelineEvent(
            id: "ev_16", t: 31.5, frame: 946, type: .shotMade, label: "2PT Make", side: .other,
            player: PlayerRef(jersey: "3", name: "Test Player 12", side: .other),
            secondaryPlayer: PlayerRef(jersey: "1", name: "Test Player 13", side: .other),
            points: 2, zone: .paint, subzone: "restricted_area")
        #expect(PlayerTimelineRowText.detail(for: shot) == "#3 Test Player 12 (ast. #1 Test Player 13) Paint \u{00B7} restricted area")
        shot.type = .shotMissed
        shot.secondaryPlayer = PlayerRef(jersey: "5", side: .scouted)
        shot.subzone = nil
        #expect(PlayerTimelineRowText.detail(for: shot) == "#3 Test Player 12 (blk. #5) Paint")

        let turnover = TimelineEvent(
            id: "ev_20", t: 40, frame: 1200, type: .turnover, label: "Turnover", side: .scouted,
            player: PlayerRef(jersey: "0", side: .scouted), secondaryPlayer: PlayerRef(jersey: "14", side: .other))
        #expect(PlayerTimelineRowText.detail(for: turnover) == "#0 (stolen by #14)")
        let period = TimelineEvent(id: "ev_1", t: 0.9, frame: 27, type: .periodStart, label: "Start of Period 1")
        #expect(PlayerTimelineRowText.detail(for: period).isEmpty)
        let timeout = TimelineEvent(
            id: "ev_9", t: 9, frame: 270, type: .timeout, label: "Timeout", secondaryPlayer: PlayerRef(jersey: "2", side: .other))
        #expect(PlayerTimelineRowText.detail(for: timeout) == "(with #2)")
    }

    @Test func possessionScoreAndConfidenceCells() {
        let names = PlayerTeamNames(scouted: "Riverside Academy", other: "Eastwood")
        var event = TimelineEvent(
            id: "ev_1", t: 10, frame: 300, type: .shotMade, label: "3PT Make", side: .scouted, possessionSide: .scouted,
            possessionID: 12, points: 3, confidence: 0.875, scoreScouted: 12, scoreOther: 10)
        #expect(PlayerTimelineRowText.possession(for: event, teamNames: names) == "\u{25B8} RA 12")
        #expect(PlayerText.possessionHelp(number: 12, team: "Riverside Academy") == "Possession 12: Riverside Academy has the ball")
        #expect(PlayerTimelineRowText.points(for: event) == "+3 ")
        #expect(PlayerTimelineRowText.score(for: event) == "12-10")
        #expect(PlayerTimelineRowText.confidence(for: event) == "88%")
        #expect(!PlayerTimelineRowText.isLowConfidence(event))

        event.possessionSide = .other
        event.possessionID = nil
        #expect(PlayerTimelineRowText.possession(for: event, teamNames: names) == "\u{25B8} EAS")
        event.possessionSide = nil
        #expect(PlayerTimelineRowText.possession(for: event, teamNames: names) == nil)
        event.points = 0
        #expect(PlayerTimelineRowText.points(for: event) == nil)
        event.confidence = 0.49
        #expect(PlayerTimelineRowText.isLowConfidence(event))
        event.confidence = .nan
        #expect(!PlayerTimelineRowText.isLowConfidence(event))  // as the web: NaN < 0.5 is false
    }

    @Test func voiceOverHearsTheWholeRow() {
        let event = TimelineEvent(
            id: "ev_1", t: 75, frame: 2250, type: .shotMade, label: "2PT Make", side: .other,
            player: PlayerRef(jersey: "3", name: "Test Player 1", side: .other), possessionSide: .other, possessionID: 4,
            points: 2, zone: .paint, confidence: 0.9, scoreScouted: 4, scoreOther: 6)
        let spoken = PlayerTimelineRowText.spokenSummary(for: event, teamNames: Self.names)
        #expect(spoken.contains("2PT Make, #3 Test Player 1 Paint, Test Team B, Possession 4, Test Team B"))
        #expect(spoken.hasSuffix("plus 2, score 4 to 6, confidence 90%"))
    }
}
