#if os(iOS)
import XCTest

/// Sign-in on iPhone (02 §11): the address checks that need no password, one wrong password (opt-in), the
/// result sheet, sign-out and signing in again.
final class iPhoneSignInTests: XCTestCase {
    /// The address is checked before anything is sent: empty, a pasted page address (with the fix offered),
    /// plain http to a dotted name, and a port where nothing answers. No password is typed.
    @MainActor
    func testAddressChecks() throws {
        let kit = try iPhoneKit(self, tag: "address")
        let app = kit.app
        kit.launchSignedIn()
        kit.signOut()
        let address = app.textFields["Server address"]
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(kit.wait(address, 10))
        // Signing out keeps the address and the username, and clears the password.
        XCTAssertEqual(address.value as? String, kit.driver.server.origin, "sign-out forgot the address")
        XCTAssertEqual(app.textFields["Username"].value as? String, kit.driver.server.username)
        kit.shot("signed-out")

        kit.type("", into: address)
        XCTAssertFalse(signIn.isEnabled, "Sign in is enabled without an address")
        kit.shot("empty")

        // A page address: "Type only the server address" and a button with the address to use.
        kit.type("\(kit.driver.server.origin)/games/g_123", into: address)
        kit.tap(signIn)
        XCTAssertTrue(kit.wait(kit.any("Type only the server address"), 5))
        XCTAssertTrue(kit.any("Leave out \u{201C}/games/g_123\u{201D}. Use \(kit.driver.server.origin) instead.").exists)
        kit.shot("path")
        kit.tap(kit.button("Use \(kit.driver.server.origin)"))
        XCTAssertEqual(address.value as? String, kit.driver.server.origin, "Use … did not put the address in")
        XCTAssertFalse(kit.any("Type only the server address").exists, "the error stayed after taking the fix")

        // Plain http to a name with dots needs https (DESIGN §4).
        kit.type("http://scout.example.org", into: address)
        kit.tap(signIn)
        XCTAssertTrue(kit.wait(kit.any("This address needs https"), 10))
        kit.shot("https-needed")

        // A port with nothing behind it.
        kit.type("http://127.0.0.1:8797", into: address)
        kit.tap(signIn)
        XCTAssertTrue(kit.wait(kit.any("Nothing answered"), 20), "no message for a port where nothing answers")
        XCTAssertTrue(kit.any("No Basketball Scout server is answering at 127.0.0.1:8797.").exists)
        kit.shot("nothing-answered")

        // The right address and password: signed in again.
        kit.signIn()
        kit.dismissSignInResult()
        XCTAssertTrue(kit.driver.gamesList.waitForExistence(timeout: 20))
    }

    /// One wrong password, then the right one: the result sheet, the games list, then sign out from Settings.
    ///
    /// Opt-in (`TEST_RUNNER_SCOUT_UITEST_WRONG_PASSWORD=1`): every wrong password counts towards the server's
    /// lockout of this address (10 in 5 minutes), so routine runs leave it out.
    @MainActor
    func testWrongPasswordThenSignInAndOut() throws {
        guard ProcessInfo.processInfo.environment["SCOUT_UITEST_WRONG_PASSWORD"] == "1" else {
            throw XCTSkip("Types a wrong password (counts towards the server's lockout): set TEST_RUNNER_SCOUT_UITEST_WRONG_PASSWORD=1 to run it.")
        }
        let kit = try iPhoneKit(self, tag: "password")
        let app = kit.app
        kit.launchSignedIn()
        kit.signOut()
        let address = app.textFields["Server address"]
        kit.type(kit.driver.server.origin, into: address)
        // Return moves on to the username, then to the password, and signs in from there.
        let username = app.textFields["Username"]
        kit.type(kit.driver.server.username, into: username)
        username.typeText("\n")
        let password = app.secureTextFields["Password"]
        guard kit.wait(password, until: "hasKeyboardFocus == true", 5) else {
            XCTFail("the password field did not get the keyboard")
            return
        }
        password.typeText("not-the-password-\(Int.random(in: 100...999))\n")
        let carryOn = app.alerts.buttons["Continue"].firstMatch
        if carryOn.waitForExistence(timeout: 4) {
            kit.shot("plain-http-warning")
            XCTAssertTrue(kit.any("Your password will be sent unencrypted").exists)
            carryOn.tap()
        }
        XCTAssertTrue(kit.wait(kit.any("Wrong username or password"), 15), "no message for a wrong password")
        XCTAssertTrue(kit.any("The server didn't accept that username and password.").exists)
        let typed = (password.value as? String) ?? ""
        XCTAssertTrue(typed.isEmpty || typed == password.placeholderValue, "the wrong password was kept in the field")
        kit.shot("wrong-password")

        kit.typeSecure(kit.driver.server.password + "\n", into: password)
        if carryOn.waitForExistence(timeout: 3) { carryOn.tap() }
        // The result sheet: the server runs the mock processor (demo mode) without Claude.
        let sheetContinue = app.navigationBars.buttons["Continue"].firstMatch
        if kit.wait(sheetContinue, 10) {
            XCTAssertTrue(kit.any("Signed in to \(kit.driver.server.origin).").exists)
            kit.shot("result-sheet")
            sheetContinue.tap()
        }
        XCTAssertTrue(kit.driver.gamesList.waitForExistence(timeout: 20))
        kit.shot("signed-in")
        // Sign out asks first and names the server.
        kit.tap(app.buttons["Settings"].firstMatch)
        let signOut = app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).firstMatch
        kit.tap(signOut)
        XCTAssertTrue(kit.wait(kit.any("Sign out of \(kit.driver.server.origin)?"), 5), "sign-out does not ask first")
        kit.shot("sign-out-question")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).allElementsBoundByIndex.last { $0.isHittable }?.tap()
        XCTAssertTrue(kit.wait(address, 20), "sign-out did not show the sign-in screen")
        kit.signIn()
        kit.dismissSignInResult()
        XCTAssertTrue(kit.driver.gamesList.waitForExistence(timeout: 20))
    }
}
#endif
