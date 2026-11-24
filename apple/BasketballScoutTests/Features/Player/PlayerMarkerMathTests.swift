import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// The marker strip and previous / next event (06 §7.2–§7.3; player.js:255-268, 435-500). Expected
/// fixture values come from a port of the web's code.
struct PlayerMarkerMathTests {
    private static func event(_ id: String, _ t: Double, _ type: EventType = .shotMade, side: TeamSide? = .scouted) -> TimelineEvent {
        TimelineEvent(id: id, t: t, frame: t.isFinite ? Int(t * 30) : 0, type: type, label: type.label, side: side)
    }

    private static func fixtureMarkers() throws -> [TimelineEvent] {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        return PlayerMarkerMath.markers(from: analysis.sortedTimeline, typeFilterActive: false)
    }

    @Test func markersLeaveOutNoisyRowsUnlessTypesAreFiltered() throws {
        let rows = [Self.event("a", 1, .pass), Self.event("b", 2, .shotMade), Self.event("c", 3, .possessionChange),
                    Self.event("d", 4, .screen), Self.event("e", .nan, .foul)]
        #expect(PlayerMarkerMath.markers(from: rows, typeFilterActive: false).map(\.id) == ["b"])
        #expect(PlayerMarkerMath.markers(from: rows, typeFilterActive: true).map(\.id) == ["a", "b", "c", "d"])
        #expect(try Self.fixtureMarkers().count == 105)
    }

    @Test func nextAndPreviousEventMatchTheWebOnTheFixture() throws {
        let markers = try Self.fixtureMarkers()
        func next(_ now: Double) -> String? { PlayerMarkerMath.nextMarker(markers, after: now, preroll: 3)?.id }
        func previous(_ now: Double) -> String? { PlayerMarkerMath.previousMarker(markers, before: now, preroll: 3)?.id }
        #expect(next(0) == "ev_00007")
        #expect(previous(0) == "ev_00002")
        #expect(next(30) == "ev_00018")
        #expect(previous(30) == "ev_00013")
        #expect(next(100) == "ev_00047")
        #expect(previous(100) == "ev_00045")
        #expect(next(10_000) == nil)
        #expect(PlayerMarkerMath.previousMarker([], before: 10, preroll: 3) == nil)
    }

    @Test func navigationSkipsEventsWithinAQuarterSecond() {
        let markers = [Self.event("a", 13), Self.event("b", 20)]
        // Standing on a's jump target (10 s): "next" goes to b, "previous" does not stay on a.
        #expect(PlayerMarkerMath.nextMarker(markers, after: 10, preroll: 3)?.id == "b")
        #expect(PlayerMarkerMath.nextMarker(markers, after: 9.74, preroll: 3)?.id == "a")
        #expect(PlayerMarkerMath.previousMarker(markers, before: 10, preroll: 3) == nil)
        #expect(PlayerMarkerMath.previousMarker(markers, before: 10.25, preroll: 3)?.id == "a")
    }

    @Test func clicksSnapToTheNearestMarkerWithinTolerance() {
        let markers = [Self.event("a", 10), Self.event("b", 12), Self.event("c", 30)]
        #expect(PlayerMarkerMath.nearestMarker(markers, to: 10.8, tolerance: 1)?.id == "a")
        #expect(PlayerMarkerMath.nearestMarker(markers, to: 11.4, tolerance: 1)?.id == "b")
        #expect(PlayerMarkerMath.nearestMarker(markers, to: 11, tolerance: 1)?.id == "a")  // a tie: the earlier
        #expect(PlayerMarkerMath.nearestMarker(markers, to: 20, tolerance: 1) == nil)
        #expect(PlayerMarkerMath.nearestMarker(markers, to: 9.5, tolerance: 1)?.id == "a")  // before the first
        #expect(PlayerMarkerMath.nearestMarker([], to: 9.5, tolerance: 1) == nil)
    }

    @Test func positionsAndTimesOnTheStrip() {
        #expect(PlayerMarkerMath.x(for: 300, duration: 600, width: 800) == 400)
        #expect(PlayerMarkerMath.time(at: 200, duration: 600, width: 800) == 150)
        #expect(PlayerMarkerMath.x(for: 10, duration: 0, width: 800) == 0)
        #expect(PlayerMarkerMath.time(at: 10, duration: 600, width: 0) == 0)
        // The film's length when known, else the analysis's.
        #expect(PlayerMarkerMath.duration(player: 598.5, analysis: 600) == 598.5)
        #expect(PlayerMarkerMath.duration(player: nil, analysis: 600) == 600)
        #expect(PlayerMarkerMath.duration(player: .nan, analysis: 600) == 600)
        #expect(PlayerMarkerMath.duration(player: 0, analysis: 0) == nil)
    }

    @Test func ticksSitInTheirTeamsLane() {
        // 34-point strip, 5-point band: two 13.5-point lanes (player.js:446-452).
        let scouted = PlayerMarkerMath.laneRect(for: Self.event("a", 1, side: .scouted), x: 100, height: 34, bandHeight: 5)
        #expect(scouted == CGRect(x: 99, y: 1, width: 2, height: 13.5))
        let other = PlayerMarkerMath.laneRect(for: Self.event("b", 1, side: .other), x: 100, height: 34, bandHeight: 5)
        #expect(other == CGRect(x: 99, y: 14.5, width: 2, height: 13.5))
        let noTeam = PlayerMarkerMath.laneRect(for: Self.event("c", 1, side: nil), x: 100, height: 34, bandHeight: 5)
        #expect(noTeam == CGRect(x: 99, y: 1, width: 2, height: 27))
    }

    @Test func theLegendListsTheCategoriesPresentInOrder() {
        let markers = [Self.event("a", 1, .foul), Self.event("b", 2, .shotMissed), Self.event("c", 3, .freeThrowMade),
                       Self.event("d", 4, .timeout)]
        #expect(PlayerMarkerMath.legendCategories(markers) == [.make, .miss, .foul, .game])
        #expect(PlayerMarkerMath.legendCategories([]).isEmpty)
    }

    @Test func theHoverTipNamesTheMarkerOrTheTime() {
        var shot = Self.event("a", 75.9, .shotMade)
        shot.label = "2PT Make"
        shot.player = PlayerRef(jersey: "3", name: "Test Player 1", side: .scouted)
        #expect(PlayerMarkerMath.tipText(marker: shot, time: 76) == "1:15 2PT Make \u{00B7} #3 Test Player 1")
        shot.player = nil
        #expect(PlayerMarkerMath.tipText(marker: shot, time: 76) == "1:15 2PT Make")
        #expect(PlayerMarkerMath.tipText(marker: nil, time: 3725) == "1:02:05")
    }
}
