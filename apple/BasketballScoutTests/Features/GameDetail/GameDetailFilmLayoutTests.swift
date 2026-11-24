import CoreGraphics
import SwiftUI
import Testing
@testable import BasketballScout

/// Where the film card and the event timeline go (03 §7.3 row 7; app.css `.game-layout`).
@MainActor
struct GameDetailFilmLayoutTests {
    /// A film card: a 16:9 picture plus 120 points of controls.
    private func filmHeight(_ width: CGFloat) -> CGFloat { width * 9 / 16 + 120 }

    private func arrange(_ mode: GameDetailFilmLayout.Mode, width: CGFloat, hasTimeline: Bool = true)
        -> (film: CGRect, timeline: CGRect?, size: CGSize)
    {
        GameDetailFilmLayout.arrange(mode: mode, width: width, spacing: 16, hasTimeline: hasTimeline, filmHeight: filmHeight)
    }

    @Test func sideBySideTheTimelineIsAsTallAsTheFilmCard() {
        let result = arrange(.sideBySide(timelineWidth: 400, minimumHeight: 440), width: 1216)

        #expect(result.film == CGRect(x: 0, y: 0, width: 800, height: 570))
        #expect(result.timeline == CGRect(x: 816, y: 0, width: 400, height: 570))
        #expect(result.size == CGSize(width: 1216, height: 570))
    }

    @Test func sideBySideAShortFilmCardStillLeavesRoomForTheTimeline() {
        let result = GameDetailFilmLayout.arrange(
            mode: .sideBySide(timelineWidth: 330, minimumHeight: 440), width: 916, spacing: 16, hasTimeline: true
        ) { _ in 120 }  // the "Film not available" notice

        #expect(result.film.height == 120)
        #expect(result.timeline?.height == 440)
        #expect(result.size.height == 440)
    }

    /// Stacked, the timeline takes its own height (its list is 55 % of the screen, plus its filters and footer),
    /// so nothing below it is overlapped.
    @Test func stackedTheTimelineFollowsAtItsOwnHeight() {
        let result = GameDetailFilmLayout.arrange(
            mode: .stacked, width: 361, spacing: 16, hasTimeline: true, filmHeight: filmHeight, timelineHeight: { _ in 610 })

        #expect(result.film.width == 361)
        #expect(abs(result.film.height - (361 * 9 / 16 + 120)) < 0.001)
        #expect(result.timeline?.minY == result.film.maxY + 16)
        #expect(result.timeline?.size == CGSize(width: 361, height: 610))
        #expect(abs(result.size.height - (result.film.height + 16 + 610)) < 0.001)
    }

    // MARK: - Bringing the film into view (06 §7.3 "reveal")

    @Test func aWhollyVisibleFilmStaysWhereItIs() {
        let reveal = GameDetailFilmReveal(filmFrame: CGRect(x: 16, y: 120, width: 600, height: 400), viewportHeight: 800)
        #expect(reveal.isWhollyVisible)
        #expect(!reveal.needsScroll)
    }

    @Test func aFilmScrolledAwayIsBroughtBackCentred() {
        let above = GameDetailFilmReveal(filmFrame: CGRect(x: 16, y: -900, width: 600, height: 400), viewportHeight: 800)
        #expect(above.needsScroll)
        #expect(above.anchor == .center)
        let halfway = GameDetailFilmReveal(filmFrame: CGRect(x: 16, y: -150, width: 600, height: 400), viewportHeight: 800)
        #expect(halfway.needsScroll)
        let below = GameDetailFilmReveal(filmFrame: CGRect(x: 16, y: 700, width: 600, height: 400), viewportHeight: 800)
        #expect(below.needsScroll)
    }

    @Test func aFilmTallerThanTheScreenIsShownFromItsTop() {
        // iPhone in landscape: the film card is taller than what is visible.
        let reveal = GameDetailFilmReveal(filmFrame: CGRect(x: 0, y: -200, width: 800, height: 420), viewportHeight: 330)
        #expect(reveal.needsScroll)
        #expect(reveal.anchor == .top)
    }

    @Test func beforeTheFirstMeasurementNothingMoves() {
        #expect(!GameDetailFilmReveal.unknown.needsScroll)
        #expect(!GameDetailFilmReveal(filmFrame: .zero, viewportHeight: 0).needsScroll)
    }

    @Test func aloneTheFilmIsAtMost1100PointsWide() {
        let wide = arrange(.solo(maximumWidth: 1100), width: 1400, hasTimeline: false)
        let narrow = arrange(.solo(maximumWidth: 1100), width: 700, hasTimeline: false)

        #expect(wide.film.width == 1100)
        #expect(wide.timeline == nil)
        #expect(wide.size == CGSize(width: 1400, height: 738.75))  // 1100 × 9/16 + 120
        #expect(narrow.film.width == 700)
    }

    @Test func withoutATimelineTheFilmTakesTheWholeWidth() {
        let result = arrange(.sideBySide(timelineWidth: 400, minimumHeight: 440), width: 1000, hasTimeline: false)

        #expect(result.film.width == 1000)
        #expect(result.timeline == nil)
    }
}
