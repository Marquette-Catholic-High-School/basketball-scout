#if os(iOS)
import XCTest

/// Lifecycle on iPhone: background and foreground keep the page and pick up changes made meanwhile
/// (resync on foreground, 09 R29); a relaunch stays signed in without asking for the password.
final class iPhoneLifecycleTests: XCTestCase {
    /// Home, then back: the game page is still there and shows what changed on the server meanwhile
    /// (another device renamed the opponent).
    @MainActor
    func testForegroundRefreshesTheGamePage() async throws {
        let kit = try iPhoneKit(self, tag: "foreground")
        let api = kit.api
        let team = "iPT Foreground \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.any("\(team) vs Test Opponent"), 10))
        kit.shot("before")
        XCUIDevice.shared.press(.home)
        try await api.send("PATCH", "/api/games/\(gameID)", json: ["other_team": "Test Rivals"])
        kit.pause(2)
        kit.app.activate()
        XCTAssertTrue(kit.wait(kit.app.buttons["Game actions"].firstMatch, 10), "the game page is gone after the foreground")
        XCTAssertTrue(kit.wait(kit.any("\(team) vs Test Rivals"), 15), "the page did not reload on returning to the foreground")
        kit.shot("after")
    }

    /// A relaunch while signed in goes straight to the games list (no sign-in screen, no password).
    @MainActor
    func testRelaunchStaysSignedIn() async throws {
        let kit = try iPhoneKit(self, tag: "relaunch")
        let api = kit.api
        let team = "iPT Relaunch \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.app.terminate()
        kit.app.launch()
        let list = kit.driver.gamesList
        let address = kit.app.textFields["Server address"]
        kit.driver.waitForAny([list, address], timeout: 30)
        kit.shot("relaunched")
        XCTAssertTrue(list.exists, "the relaunch did not go to the games list")
        XCTAssertFalse(address.exists, "the relaunch asked to sign in again")
        XCTAssertTrue(kit.wait(kit.gameRow("\(team) vs Test Opponent"), 15), "the list did not load after the relaunch")
    }
}
#endif
