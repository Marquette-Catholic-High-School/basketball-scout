import CoreGraphics
import Testing
@testable import BasketballScout

/// How the game page arranges film, timeline and header items for the space it has (03 §7.3 row 7, 07 §10.6).
@MainActor
struct GameDetailLayoutTests {
    // MARK: - Page layout

    @Test func anIPhoneStacksEverything() {
        let layout = GameDetailLayout(viewport: CGSize(width: 393, height: 852))

        #expect(layout.contentWidth == 361)
        #expect(!layout.isWide)
        #expect(!layout.toolbarShowsTitles)
    }

    @Test func theMacsDefaultWindowShowsFilmAndTimelineSideBySide() {
        // 1280-point window minus the 340-point sidebar.
        let layout = GameDetailLayout(viewport: CGSize(width: 940, height: 800))

        #expect(layout.contentWidth == 908)
        #expect(layout.isWide)
        #expect(abs(layout.timelineWidth - 908 * 0.36) < 0.001)
        #expect(abs(layout.filmWidth - (908 - 16 - 908 * 0.36)) < 0.001)
    }

    @Test func anIPadBesideTheSidebarStacks() {
        // 11-inch iPad in landscape: 1194 points minus the sidebar.
        let layout = GameDetailLayout(viewport: CGSize(width: 874, height: 834))
        #expect(!layout.isWide)
    }

    @Test func theTimelineColumnStaysBetween320And440Points() {
        #expect(GameDetailLayout(viewport: CGSize(width: 2000, height: 1000)).timelineWidth == 440)
        #expect(abs(GameDetailLayout(viewport: CGSize(width: 932, height: 1000)).timelineWidth - 324) < 0.001)
        #expect(GameDetailLayout(viewport: CGSize(width: 880, height: 1000)).timelineWidth == 320)
    }

    @Test func thePageStopsGrowingAt1440Points() {
        let layout = GameDetailLayout(viewport: CGSize(width: 2400, height: 1200))
        #expect(layout.contentWidth == GameDetailLayout.maximumContentWidth)
        #expect(layout.toolbarShowsTitles)
    }

    @Test func beforeTheFirstMeasurementThePageIsCompact() {
        let layout = GameDetailLayout(viewport: .zero)
        #expect(layout.contentWidth == 0)
        #expect(!layout.isWide)
        #expect(layout.filmWidth == 0)
    }

    // MARK: - Header meta line (flow layout)

    private func arrange(_ sizes: [CGSize], width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        GameDetailFlowLayout.arrange(sizes: sizes, maxWidth: width, spacing: 8, lineSpacing: 6)
    }

    @Test func itemsThatFitShareOneRow() {
        let result = arrange(Array(repeating: CGSize(width: 50, height: 20), count: 3), width: 200)

        #expect(result.frames.map(\.minX) == [0, 58, 116])
        #expect(result.frames.map(\.minY) == [0, 0, 0])
        #expect(result.size == CGSize(width: 166, height: 20))
    }

    @Test func aFullRowWrapsToTheNext() {
        let result = arrange(Array(repeating: CGSize(width: 50, height: 20), count: 3), width: 120)

        #expect(result.frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 58, y: 0), CGPoint(x: 0, y: 26)])
        #expect(result.size == CGSize(width: 108, height: 46))
    }

    @Test func itemsInARowAreCentredVertically() {
        let result = arrange([CGSize(width: 40, height: 20), CGSize(width: 40, height: 30)], width: 200)

        #expect(result.frames[0].minY == 5)
        #expect(result.frames[1].minY == 0)
        #expect(result.size.height == 30)
    }

    @Test func anItemWiderThanTheRowIsNarrowedOnARowOfItsOwn() {
        let result = arrange([CGSize(width: 40, height: 20), CGSize(width: 500, height: 24), CGSize(width: 40, height: 20)], width: 200)

        #expect(result.frames[1] == CGRect(x: 0, y: 26, width: 200, height: 24))
        #expect(result.frames[2].origin == CGPoint(x: 0, y: 56))
        #expect(result.size == CGSize(width: 200, height: 76))
    }

    @Test func nothingToPlaceTakesNoRoom() {
        let result = arrange([], width: 200)
        #expect(result.frames.isEmpty)
        #expect(result.size == .zero)
    }
}
