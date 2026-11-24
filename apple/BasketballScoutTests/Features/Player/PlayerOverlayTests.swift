import CoreGraphics
import Foundation
import Testing
@testable import BasketballScout

/// The captions over the film (04 §6.2, 06 §7.1; player.js:30-35, 343-433). Expected texts for the
/// fixture were produced by a port of the web's code run on `analysis.json`.
struct PlayerOverlayTests {
    private static let names = PlayerTeamNames(scouted: "Test Team A", other: "Test Team B")

    private static func fixtureIndex() throws -> PlayerOverlayIndex {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        return PlayerOverlayIndex(timeline: analysis.timeline, plays: analysis.plays, teamNames: names)
    }

    // MARK: - Against the web, on the fixture

    @Test func matchesTheWebOnTheFixture() throws {
        let index = try Self.fixtureIndex()

        let start = index.state(at: 0.5)
        #expect(start == .none)

        let handoff = index.state(at: 10)
        #expect(handoff.banner == .init(text: "Dribble Handoff - #20 Test Player 7 / #55 Test Player 10", accent: .team(.other)))
        #expect(handoff.caption == nil)
        #expect(handoff.score == "Test Team A 0  \u{2013}  0 Test Team B \u{25C2}")

        let defense = index.state(at: 12)
        #expect(defense.banner == .init(text: "Man-to-Man Defense", accent: .team(.scouted)))
        #expect(defense.caption == .init(text: "0:11  2PT Miss \u{00B7} #20 Test Player 7", accent: .team(.other)))

        let isolation = index.state(at: 25)
        #expect(isolation.banner?.text == "Isolation - #5 Test Player 2 / #40 Test Player 8")
        #expect(isolation.score == "\u{25B8} Test Team A 0  \u{2013}  0 Test Team B")

        #expect(index.state(at: 31.6).banner == .init(text: "Full-Court Press", accent: .team(.scouted)))
        #expect(index.state(at: 31.6).score == "Test Team A 2  \u{2013}  0 Test Team B \u{25C2}")

        let made = index.state(at: 45)
        #expect(made.banner == nil)
        #expect(made.caption == .init(text: "0:42  2PT Make \u{00B7} #55 Test Player 10", accent: .team(.other)))
        #expect(made.score == "\u{25B8} Test Team A 2  \u{2013}  2 Test Team B")

        #expect(index.state(at: 72).banner?.text == "Spot-Up - #3 Test Player 6 / #42 Test Player 9")
        #expect(index.state(at: 120).banner?.text == "Dribble Handoff - #33 Test Player 5 / #0 Test Player 1")

        // Rows without a team: the caption's accent is the "game" grey.
        let periodEnd = index.state(at: 300)
        #expect(periodEnd.caption == .init(text: "4:58  End of Period 1", accent: .category(.game)))
        #expect(periodEnd.score == "\u{25B8} Test Team A 16  \u{2013}  10 Test Team B")
        #expect(index.state(at: 599).score == "\u{25B8} Test Team A 25  \u{2013}  27 Test Team B")
    }

    @Test func nothingIsDrawnWithoutEventsOrAtAnUnknownTime() throws {
        let empty = PlayerOverlayIndex(timeline: [], plays: try Fixture.decode(GameAnalysis.self, "analysis.json").plays, teamNames: Self.names)
        #expect(empty.state(at: 10) == .none)
        #expect(try Self.fixtureIndex().state(at: .nan) == .none)
    }

    // MARK: - Rules

    private static func event(_ id: String, _ t: Double, _ type: EventType, side: TeamSide? = .scouted, player: String? = nil) -> TimelineEvent {
        TimelineEvent(
            id: id, t: t, frame: Int(t * 30), type: type, label: type.label, side: side,
            player: player.map { PlayerRef(jersey: "3", name: $0, side: side) })
    }

    private static func play(_ id: String, _ type: PlayType, _ start: Double, _ end: Double, side: TeamSide? = .scouted) -> Play {
        Play(id: id, type: type, category: type.category ?? .offense, side: side, startT: start, endT: end,
             startFrame: Int(start * 30), endFrame: Int(end * 30))
    }

    @Test func captionsSkipNoisyRowsAndLastThreeAndAHalfSeconds() {
        let index = PlayerOverlayIndex(timeline: [
            Self.event("a", 10, .shotMade, player: "Test Player 1"),
            Self.event("b", 11, .pass),
            Self.event("c", 12, .possessionChange),
            Self.event("d", 12.5, .screen),
        ], plays: [], teamNames: Self.names)
        #expect(index.caption(at: 9.99) == nil)
        #expect(index.caption(at: 10)?.id == "a")
        #expect(index.caption(at: 13.5)?.id == "a")  // pass / possession / screen never replace it
        #expect(index.caption(at: 13.51) == nil)
        // …but the score follows every row.
        #expect(index.scoreEvent(at: 12.6)?.id == "d")
        #expect(index.scoreEvent(at: 9) == nil)
    }

    @Test func theCurrentPlayPrefersOffenseAndSkipsEndedPlays() {
        let plays = [
            Self.play("pl_1", .zoneDefense, 0, 30, side: .other),
            Self.play("pl_2", .pickAndRoll, 5, 8),
            Self.play("pl_3", .manDefense, 10, 20, side: .other),
            Self.play("pl_4", .isolation, 12, 18),
        ]
        let index = PlayerOverlayIndex(timeline: [Self.event("e", 1, .jumpBall)], plays: plays, teamNames: Self.names)
        #expect(index.currentPlay(at: 6)?.id == "pl_2")
        #expect(index.currentPlay(at: 9)?.id == "pl_1")  // the offense ended: the first defense found from the latest
        #expect(index.currentPlay(at: 15)?.id == "pl_4")
        #expect(index.currentPlay(at: 19)?.id == "pl_3")
        #expect(index.currentPlay(at: 40) == nil)
    }

    @Test func theCurrentPlayLooksAtMostTwelvePlaysBack() {
        var plays = [Self.play("long", .isolation, 0, 100)]
        for number in 1...12 {
            plays.append(Self.play("d\(number)", .manDefense, Double(number), Double(number) + 0.5, side: .other))
        }
        let index = PlayerOverlayIndex(timeline: [Self.event("e", 1, .jumpBall)], plays: plays, teamNames: Self.names)
        // At 20 s the 12 latest plays are the ended defenses: the long offense (13th back) is out of reach.
        #expect(index.currentPlay(at: 20) == nil)
        // With 11 defenses after it, it is found.
        let shorter = PlayerOverlayIndex(timeline: [Self.event("e", 1, .jumpBall)], plays: Array(plays.dropLast()), teamNames: Self.names)
        #expect(shorter.currentPlay(at: 20)?.id == "long")
    }

    @Test func bannerTextFollowsTheWeb() {
        var pickAndRoll = Self.play("pl_1", .pickAndRoll, 0, 5)
        pickAndRoll.players = [
            "screener": PlayerRef(jersey: "22", name: "Test Player 2", side: .scouted),
            "ball_handler": PlayerRef(jersey: "3", name: "Test Player 1", side: .scouted),
        ]
        #expect(PlayerOverlayText.banner(for: pickAndRoll) == "Pick & Roll - #3 Test Player 1 / #22 Test Player 2")

        var zone = Self.play("pl_2", .zoneDefense, 0, 5, side: .other)
        zone.attrs = ["zone_shape": .string("2-3")]
        #expect(PlayerOverlayText.banner(for: zone) == "Zone Defense (2-3)")
        zone.attrs = ["zone_shape": .string("")]
        #expect(PlayerOverlayText.banner(for: zone) == "Zone Defense")

        var fastBreak = Self.play("pl_3", .fastBreak, 0, 5)
        fastBreak.players = [
            "ball_handler": PlayerRef(jersey: "3", side: .scouted),
            "shooter": PlayerRef(jersey: "3", side: .scouted),
        ]
        #expect(PlayerOverlayText.banner(for: fastBreak) == "Fast Break - #3")
    }

    @Test func captionAndScoreTexts() {
        var event = Self.event("e", 75.9, .shotMade, side: .other, player: "Test Player 4")
        event.label = "3PT Make"
        #expect(PlayerOverlayText.caption(for: event) == "1:15  3PT Make \u{00B7} #3 Test Player 4")
        event.player = nil
        #expect(PlayerOverlayText.caption(for: event) == "1:15  3PT Make")

        event.scoreScouted = 12
        event.scoreOther = 10
        event.possessionSide = nil
        let long = PlayerTeamNames(scouted: "Riverside Academy HS", other: "St. Anne's Prep Academy")
        #expect(PlayerOverlayText.score(for: event, teamNames: long) == "Riverside 12  \u{2013}  10 SAPA")
        event.possessionSide = .scouted
        #expect(PlayerOverlayText.score(for: event, teamNames: Self.names) == "\u{25B8} Test Team A 12  \u{2013}  10 Test Team B")
    }

    @Test func accentsUseTheTeamColoursAndGreyWithoutATeam() {
        #expect(PlayerOverlayIndex.bannerAccent(.other) == .team(.other))  // 09 R46: not the web's grey
        #expect(PlayerOverlayIndex.bannerAccent(nil) == .category(.other))
        #expect(PlayerOverlayIndex.bannerAccent(.unknown("neutral")) == .category(.other))
        #expect(PlayerOverlayIndex.captionAccent(.scouted) == .team(.scouted))
        #expect(PlayerOverlayIndex.captionAccent(nil) == .category(.game))
    }

    // MARK: - Geometry (player.js:307-314, 381-433)

    @Test func thePictureIsLetterboxedLikeTheWeb() {
        let box = CGRect(x: 0, y: 0, width: 640, height: 360)
        #expect(PlayerOverlayMetrics.pictureRect(videoSize: CGSize(width: 1920, height: 1080), in: box) == box)
        // 4:3 film in a 16:9 box: bars left and right.
        #expect(PlayerOverlayMetrics.pictureRect(videoSize: CGSize(width: 640, height: 480), in: box) == CGRect(x: 80, y: 0, width: 480, height: 360))
        // Portrait film.
        let portrait = PlayerOverlayMetrics.pictureRect(videoSize: CGSize(width: 1080, height: 1920), in: box)
        #expect(abs(portrait.width - 202.5) < 0.001 && portrait.height == 360 && abs(portrait.minX - 218.75) < 0.001)
        // Unknown size: 16:9.
        #expect(PlayerOverlayMetrics.pictureRect(videoSize: nil, in: CGRect(x: 0, y: 0, width: 400, height: 400)) == CGRect(x: 0, y: 87.5, width: 400, height: 225))
        #expect(PlayerOverlayMetrics.pictureRect(videoSize: .zero, in: .zero) == .zero)
    }

    @Test func labelSizesFollowThePictureHeight() {
        func size(_ height: CGFloat, _ scale: CGFloat = 1) -> CGFloat {
            PlayerOverlayMetrics.fontSize(pictureHeight: height, textScale: scale)
        }
        #expect(size(200) == 12)  // 8 → at least 12
        #expect(abs(size(450) - 18) < 0.0001)
        #expect(size(1080) == 22)  // at most 22
        // Larger text grows the labels, but never past 8 % of the picture.
        #expect(abs(size(450, 1.5) - 27) < 0.0001)
        #expect(abs(size(200, 3) - 16) < 0.0001)
        #expect(abs(size(450, 0.8) - 18) < 0.0001)  // smaller text keeps the web's size

        let metrics = PlayerOverlayMetrics(picture: CGRect(x: 0, y: 0, width: 800, height: 450))
        #expect(abs(metrics.size - 18) < 0.0001)
        #expect(abs(metrics.pad - 10.8) < 0.0001)
        #expect(abs(metrics.labelHeight - 28.8) < 0.0001)
        #expect(abs(metrics.bannerMaxWidth - 496) < 0.0001)
        #expect(abs(metrics.captionMaxWidth - (800 - 21.6)) < 0.0001)
        // Caption: picture bottom − pad − label height, lifted above the controls when they show.
        #expect(abs(metrics.captionTop(lift: 0) - (450 - 10.8 - 28.8)) < 0.0001)
        #expect(abs(metrics.captionTop(lift: 48) - (450 - 10.8 - 28.8 - 48)) < 0.0001)
        // Never above the top padding.
        let tiny = PlayerOverlayMetrics(picture: CGRect(x: 0, y: 0, width: 100, height: 60))
        #expect(tiny.captionTop(lift: 48) == tiny.pad)
    }
}
