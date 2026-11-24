#if os(iOS)
import XCTest

/// Dark mode, the largest text size and landscape on the main screens. These record screenshots for a
/// person to look at and check the few things a test can: the screens open and nothing essential is lost.
final class iPhoneAppearanceTests: XCTestCase {
    /// Back to light mode and portrait after each test (XCTest calls `tearDown` on the main thread).
    override func tearDown() {
        MainActor.assumeIsolated {
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
        super.tearDown()
    }

    /// Dark mode: the games list, the game page (header, team banner, player, timeline, each tab), Settings.
    @MainActor
    func testDarkMode() async throws {
        let kit = try iPhoneKit(self, tag: "dark")
        let api = kit.api
        let team = "iPT Dark \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        XCUIDevice.shared.appearance = .dark
        kit.launchSignedIn()
        kit.shot("list")
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.app.buttons["Game actions"].firstMatch, 10))
        kit.shot("page")
        for tab in ["Box score", "Shot chart", "Plays", "Scouting report", "Exports", "Data quality"] {
            kit.selectTab(tab)
            kit.scroll()
            kit.shot("tab-\(tab)")
        }
        kit.back()
        kit.tap(kit.app.buttons["Settings"].firstMatch)
        XCTAssertTrue(kit.wait(kit.app.navigationBars["Settings"], 5))
        kit.shot("settings")
        kit.tapButton("Done")
    }

    /// The largest accessibility text size: the list, the game page, the actions menu and the New game form
    /// still open and keep their words.
    @MainActor
    func testLargestText() async throws {
        let kit = try iPhoneKit(self, tag: "xxxl")
        let app = kit.app
        let api = kit.api
        let team = "iPT XXXL \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        kit.launchSignedIn()
        kit.shot("list")
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(app.buttons["Game actions"].firstMatch, 10))
        kit.shot("page")
        kit.scroll()
        kit.shot("page-scrolled")
        kit.openGameActions()
        kit.shot("actions")
        kit.tapOutside()
        kit.selectTab("Box score")
        kit.shot("box-score")
        // The Exports tab: its "Copy team numbers" button keeps its one-line width (.fixedSize), wider than the
        // screen at this size, and the whole page grows to it: every card, the header included, is cut off at
        // both edges.
        kit.selectTab("Exports")
        let copyNumbers = app.buttons["Copy team numbers"].firstMatch
        kit.scrollIntoView(copyNumbers, maxSwipes: 12)
        kit.shot("exports")
        let window = app.windows.firstMatch.frame
        kit.expectBug("bug: at the largest text size the Exports tab makes the game page wider than the screen") {
            XCTAssertTrue(copyNumbers.exists, "no Copy team numbers")
            XCTAssertLessThanOrEqual(copyNumbers.frame.width, window.width, "Copy team numbers is wider than the screen")
            XCTAssertGreaterThanOrEqual(copyNumbers.frame.minX, window.minX, "Copy team numbers starts left of the screen")
        }
        kit.scrollToTop()
        kit.shot("exports-top")
        kit.back()
        kit.tap(app.buttons["New game"].firstMatch)
        XCTAssertTrue(kit.wait(app.navigationBars["New game"], 5))
        kit.shot("new-game")
        XCTAssertTrue(kit.button("Continue to film upload").exists)
        kit.tapButton("Cancel")
    }

    /// Landscape on the game page: the header, the film and the tabs are still reachable.
    @MainActor
    func testLandscapeGamePage() async throws {
        let kit = try iPhoneKit(self, tag: "landscape")
        let api = kit.api
        let team = "iPT Landscape \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.app.buttons["Game actions"].firstMatch, 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        kit.pause(1.5)
        kit.shot("landscape")
        XCTAssertTrue(kit.app.buttons["Game actions"].firstMatch.isHittable, "the actions are out of reach in landscape")
        kit.scroll()
        kit.shot("landscape-film")
        kit.selectTab("Shot chart")
        kit.shot("landscape-shot-chart")
        XCUIDevice.shared.orientation = .portrait
        kit.pause(1)
        XCTAssertTrue(kit.wait(kit.app.buttons["Game actions"].firstMatch, 5))
    }
}
#endif
