import Foundation
import Testing
@testable import BasketballScout

/// The timeline state a game page shares between the timeline and the player (06 §8; timeline.js):
/// building off the main actor, filters surviving reloads, markers, the row following the film.
@MainActor
struct PlayerTimelineModelTests {
    private static let names = PlayerTeamNames(scouted: "Test Team A", other: "Test Team B")

    private func fixture() throws -> GameAnalysis {
        try Fixture.decode(GameAnalysis.self, "analysis.json")
    }

    @Test func rebuildPreparesTheAnalysisAndShowsEveryRow() async throws {
        let analysis = try fixture()
        let model = PlayerTimelineModel()
        #expect(model.emptyText == PlayerText.noEvents)

        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        #expect(model.index.events.count == 310)
        #expect(model.filtered.count == 310)
        #expect(model.markers.count == 105)  // no type filter: pass / possession / screen left out
        #expect(!model.isBuilding)
        #expect(model.emptyText == nil)
        #expect(model.countText == "310 of 310 events")

        // The same analysis again is not rebuilt.
        let index = model.index
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        #expect(model.index.identity == index.identity)
    }

    @Test func filtersRefilterAndDriveTheMarkers() async throws {
        let analysis = try fixture()
        let model = PlayerTimelineModel()
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)

        model.filter.team = .scouted
        #expect(model.filtered.count == 148)
        model.setType(.pass, shown: true)
        #expect(model.filtered.allSatisfy { $0.type == .pass && $0.side == .scouted })
        // With a type filter the strip shows exactly the filtered rows, passes included.
        #expect(model.markers.map(\.id) == model.filtered.map(\.id))
        #expect(model.filter.typesSummary == "1 event type")

        model.clearFilters()
        #expect(model.filtered.count == 310)
        #expect(!model.filter.isActive)

        model.showOnly(type: .steal)
        #expect(model.filtered.allSatisfy { $0.type == .steal })
        model.showOnly(team: .other)
        #expect(model.filtered.allSatisfy { $0.type == .steal && $0.side == .other })
        model.clearFilters()

        model.filter.types = [.shotMade]
        model.filter.search = "no such words"
        #expect(model.filtered.isEmpty)
        #expect(model.emptyText == PlayerText.noMatches)
    }

    @Test func theSearchBoxAppliesWhenCommitted() async throws {
        let analysis = try fixture()
        let model = PlayerTimelineModel()
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        model.searchText = "corner"
        #expect(model.filtered.count == 310)  // not yet: the view commits after a pause
        model.commitSearch()
        #expect(model.filtered.count == 4)
        model.clearFilters()
        #expect(model.searchText.isEmpty && model.filtered.count == 310)
    }

    @Test func filtersSurviveANewAnalysisWhenTheyStillApply() async throws {
        var analysis = try fixture()
        let model = PlayerTimelineModel()
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        model.filter = PlayerTimelineFilter(team: .other, types: [.shotMade, .timeout], search: "paint")
        let player = try #require(model.index.playerOptions.first)
        model.filter.playerKey = player.key

        // A re-run: a newer analysis without that player.
        analysis.generatedAt = analysis.generatedAt.addingTimeInterval(60)
        analysis.timeline = analysis.timeline.map { event in
            var event = event
            if PlayerTimelinePlayerOption.key(for: event.player) == player.key { event.player = nil }
            if PlayerTimelinePlayerOption.key(for: event.secondaryPlayer) == player.key { event.secondaryPlayer = nil }
            return event
        }
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        #expect(model.filter.team == .other)
        #expect(model.filter.types == [.shotMade])  // no timeout rows in this film
        #expect(model.filter.search == "paint")
        #expect(model.filter.playerKey == nil)
        #expect(model.filtered.allSatisfy { $0.side == .other && $0.type == .shotMade })
    }

    @Test func noAnalysisEmptiesTheTimeline() async throws {
        let analysis = try fixture()
        let model = PlayerTimelineModel()
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)
        await model.rebuild(analysis: nil, gameID: analysis.gameID, teamNames: Self.names)
        #expect(model.index.isEmpty)
        #expect(model.filtered.isEmpty && model.markers.isEmpty)
        #expect(model.emptyText == PlayerText.noEvents)
    }

    @Test func theCurrentRowFollowsTheFilm() async throws {
        let analysis = try fixture()
        let model = PlayerTimelineModel()
        await model.rebuild(analysis: analysis, gameID: analysis.gameID, teamNames: Self.names)

        model.updateCurrentRow(time: 0)
        #expect(model.currentRowID == nil)
        model.updateCurrentRow(time: 0.9)
        #expect(model.currentRowID == "ev_00001")
        model.updateCurrentRow(time: 31.5)
        #expect(model.currentRowID == "ev_00014")
        model.updateCurrentRow(time: 600)
        #expect(model.currentRowID == "ev_00245")
        // 50 ms early counts (timeline.js:236).
        let row = model.filtered[20]
        model.updateCurrentRow(time: row.t - 0.04)
        let current = model.filtered.first { $0.id == model.currentRowID }
        #expect(current.map { $0.t >= row.t } == true)

        // A filter moves the current row to the last shown row at that time.
        model.updateCurrentRow(time: 31.5)
        model.filter.team = .scouted
        let expected = model.filtered.last { $0.t <= 31.55 }?.id
        #expect(model.currentRowID == expected)
        #expect(PlayerTimelineModel.currentRow(in: model.filtered, at: .nan) == nil)
    }

    @Test func choosingARowAsksForTheFilm() {
        let model = PlayerTimelineModel()
        #expect(model.revealRequests == 0)
        model.requestReveal()
        model.requestReveal()
        #expect(model.revealRequests == 2)
    }

    @Test func theGameContextSharesOneStateForThePage() {
        let context = PlayerPreviewData.context()
        #expect(context.playerTimeline === context.playerTimeline)
        #expect(context.playerController === context.playerController)
        #expect(context.playerController.playback === context.playback)
        #expect(context.playerTeamNames == PlayerPreviewData.teamNames)
        #expect(context.playerFilmInputs == PlayerFilmInputs(game: PlayerPreviewData.game, revision: 0))
        #expect(context.playerRevealRequests == 0)
        let other = PlayerPreviewData.context()
        #expect(other.playerTimeline !== context.playerTimeline)
    }

    @Test func thePreviewDataIsShapedLikeTheServers() throws {
        let analysis = PlayerPreviewData.analysis
        let data = try ScoutJSON.encode(analysis)
        let decoded = try ScoutJSON.decode(GameAnalysis.self, from: data)
        #expect(decoded.timeline.count == analysis.timeline.count)
        #expect(Set(analysis.timeline.map(\.id)).count == analysis.timeline.count)
        let names = analysis.timeline.flatMap { [$0.player?.name, $0.secondaryPlayer?.name] }.compactMap { $0 }
        #expect(names.allSatisfy { $0.hasPrefix("Test Player ") })
        let all = PlayerPreviewData.index.overlay.state(at: 12.5)
        #expect(all.banner == .init(text: "Man-to-Man Defense", accent: .team(.scouted)))
        #expect(all.caption == .init(text: "0:12  3PT Miss \u{00B7} #22 Test Player 6", accent: .team(.other)))
        #expect(all.score == "Test Team A 0  \u{2013}  0 Test Team B \u{25C2}")
        let later = PlayerPreviewData.index.overlay.state(at: 31.6)
        #expect(later.banner == nil)
        #expect(later.caption?.text == "0:31  3PT Make \u{00B7} #5 Test Player 5")
        #expect(later.score == "\u{25B8} Test Team A 2  \u{2013}  3 Test Team B")
        #expect(PlayerPreviewData.index.overlay.state(at: 30).banner?.text == "Isolation - #5 Test Player 5")
    }
}
