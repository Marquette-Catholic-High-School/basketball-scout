import XCTest

/// Sign-in on iPad (02 §11): address problems explained before any password is sent, the result sheet,
/// sign-out. The wrong-password check is opt-in (it counts against the server's lockout).
final class iPadSignInUITests: XCTestCase {
    @MainActor
    func testAddressProblemsAreExplainedBeforeSigningIn() throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        driver.iPadRotate(.portrait)
        app.launch()
        let address = app.textFields["Server address"]
        // The sign-in form shows for a moment at launch even when a saved password signs in by itself, so
        // wait for the games list first.
        if driver.gamesList.waitForExistence(timeout: 20) {
            driver.iPadSignOut()
        }
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        driver.snapshot("sign-in")

        // Nothing typed: Sign in waits for an address.
        driver.replaceText(in: address, with: "x")
        address.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(app.buttons["Sign in"].isEnabled, "Sign in is enabled without an address")

        // A path is refused before anything is sent, and the fix is one tap away.
        driver.replaceText(in: address, with: driver.server.origin + "/games")
        driver.tapButton("Sign in")
        driver.expectText("Type only the server address")
        let use = app.buttons["Use \(driver.server.origin)"]
        XCTAssertTrue(use.waitForExistence(timeout: 5), "no Use … button")
        driver.snapshot("address with a path")
        use.tap()
        XCTAssertEqual(address.value as? String, driver.server.origin)

        // Nothing listens on port 9.
        driver.replaceText(in: address, with: "http://127.0.0.1:9")
        driver.tapButton("Sign in")
        driver.expectText("Nothing answered", timeout: 40)
        driver.expectText("No Basketball Scout server is answering at 127.0.0.1:9.")
        driver.snapshot("nothing answered")

        // Only http and https.
        driver.replaceText(in: address, with: "ftp://127.0.0.1")
        driver.tapButton("Sign in")
        driver.expectText("That doesn't look like a server address")

        // The real server (no plain-http question for a loopback address): the result sheet says it is a demo server.
        driver.replaceText(in: address, with: driver.server.origin)
        driver.replaceText(in: app.textFields["Username"], with: driver.server.username)
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText(driver.server.password)
        driver.tapButton("Sign in")
        XCTAssertTrue(app.navigationBars["Connected"].waitForExistence(timeout: 30), "no result sheet")
        driver.expectText("Signed in to \(driver.server.origin).")
        driver.expectText("Demo mode")
        driver.snapshot("connected sheet")
        driver.tapButton("Continue")
        XCTAssertTrue(driver.gamesList.waitForExistence(timeout: 30))
    }

    @MainActor
    func testSignOutKeepsTheAddressAndAsksForThePassword() throws {
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        driver.iPadLaunch(self)
        driver.openSettings()
        driver.expectText(driver.server.origin)
        driver.snapshot("settings L")
        driver.tapButton("Done")
        driver.iPadSignOut()
        driver.snapshot("signed out L")
        XCTAssertEqual(app.textFields["Server address"].value as? String, driver.server.origin, "the address was not kept")
        XCTAssertEqual(app.textFields["Username"].value as? String, driver.server.username)
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(((password.value as? String) ?? "").isEmpty || password.value as? String == "Password",
                      "the password was kept after signing out")
        password.tap()
        password.typeText(driver.server.password)
        driver.tapButton("Sign in")
        driver.dismissSignInResultIfShown()
        XCTAssertTrue(driver.gamesList.waitForExistence(timeout: 30))
        driver.iPadRotate(.portrait)
    }

    /// Sends one wrong password, so it is skipped unless SCOUT_UITEST_WRONG_PASSWORD=1 reaches the runner
    /// (TEST_RUNNER_SCOUT_UITEST_WRONG_PASSWORD=1): ten wrong tries in five minutes lock the address out.
    @MainActor
    func testWrongPasswordIsRefusedAndCleared() throws {
        guard ProcessInfo.processInfo.environment["SCOUT_UITEST_WRONG_PASSWORD"] == "1" else {
            throw XCTSkip("Sends a wrong password; set TEST_RUNNER_SCOUT_UITEST_WRONG_PASSWORD=1 to run it.")
        }
        let driver = try ScoutAppDriver(self)
        let app = driver.app
        driver.iPadLaunch(self)
        driver.iPadSignOut()
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("not-the-password")
        driver.tapButton("Sign in")
        driver.expectText("Wrong username or password", timeout: 30)
        driver.expectText("The server didn't accept that username and password.")
        driver.snapshot("wrong password L")
        XCTAssertTrue(((password.value as? String) ?? "").isEmpty || password.value as? String == "Password",
                      "the wrong password was left in the field")
        password.tap()
        password.typeText(driver.server.password)
        driver.tapButton("Sign in")
        driver.dismissSignInResultIfShown()
        XCTAssertTrue(driver.gamesList.waitForExistence(timeout: 30))
        driver.iPadRotate(.portrait)
    }
}
