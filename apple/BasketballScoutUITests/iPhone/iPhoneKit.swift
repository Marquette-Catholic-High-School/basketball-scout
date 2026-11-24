#if os(iOS)
import XCTest

/// What the iPhone tests share, on top of the shared `ScoutAppDriver`: numbered screenshots named after the
/// test, finding elements by their visible text, scrolling to them, typing into fields reliably, the game
/// page's "Game actions" menu and analysis tabs, and signing out.
///
/// Every helper of the iPhone suite is a type or member prefixed `iPhone` or lives in this type (one Swift
/// module with the other testers' helpers).
@MainActor
final class iPhoneKit {
    let driver: ScoutAppDriver
    let app: XCUIApplication
    let api: ScoutUITestAPI
    private unowned let test: XCTestCase
    private let tag: String
    private var shotNumber = 0

    /// - Parameter tag: a short name for the screenshots ("iPhone-<tag>-NN-<name>").
    init(_ test: XCTestCase, tag: String) throws {
        driver = try ScoutAppDriver(test)
        app = driver.app
        api = driver.api
        self.test = test
        self.tag = tag
    }

    // MARK: Screenshots and the element tree

    /// A screenshot attached to the result (kept always): "iPhone-<tag>-NN-<name>".
    func shot(_ name: String) {
        shotNumber += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "iPhone-%@-%02d-%@", tag, shotNumber, name)
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// The app's accessibility tree as a text attachment (for finding labels while writing tests).
    func tree(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = String(format: "tree-%@-%02d-%@", tag, shotNumber, name)
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// A screenshot and the tree.
    func look(_ name: String) {
        shot(name)
        tree(name)
    }

    // MARK: Finding

    /// The first element of any type whose label contains `text`.
    func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first element of any type whose label is exactly `text`.
    func exact(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// The first static text whose label contains `text`.
    func text(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first button whose label is `label`.
    func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The first button whose label begins with `prefix`.
    func buttonStarting(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// The first button whose label contains `text`.
    func buttonContaining(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first text field whose placeholder is `placeholder` (SwiftUI forms name fields by their prompt).
    func field(placeholder: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    /// A button of the alert on screen (SwiftUI `.alert` / the app's confirmations).
    func alertButton(_ label: String) -> XCUIElement {
        app.alerts.buttons[label].firstMatch
    }

    // MARK: Waiting

    @discardableResult
    func wait(_ element: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Waits until `element` is gone (true) or `timeout` passed (false).
    @discardableResult
    func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Waits until `predicate` (on `element`) holds.
    @discardableResult
    func wait(_ element: XCUIElement, until predicate: String, _ timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits until `element`'s label begins with `prefix` (any characters, no predicate quoting).
    @discardableResult
    func wait(_ element: XCUIElement, labelStartsWith prefix: String, _ timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Lets the app run for `seconds` (animations, polling) without blocking the main run loop.
    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Known bugs

    /// Checks a known bug without ending the test there: the failures inside `block` are expected
    /// (XCTExpectFailure, strict: the block must fail while the bug is there), and the test goes on after
    /// them. The suite stops at the first issue otherwise, an expected one included.
    /// - Parameter strict: false for a bug that shows only sometimes (the check may pass).
    func expectBug(_ reason: String, strict: Bool = true, _ block: () -> Void) {
        let carryOn = test.continueAfterFailure
        test.continueAfterFailure = true
        let options = XCTExpectedFailure.Options()
        options.isStrict = strict
        XCTExpectFailure(reason, options: options) { block() }
        test.continueAfterFailure = carryOn
    }

    // MARK: Scrolling

    /// True when `element` exists and can be tapped (never asks a missing element whether it is hittable,
    /// which would end the test).
    func isVisible(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let visible = frame.intersection(contentArea)
        guard !visible.isNull, visible.height >= min(frame.height, 30) - 0.5, visible.width >= min(frame.width, 20) - 0.5 else {
            return false
        }
        return isHittableSafely(element)
    }

    /// `isHittable`, asked only when the element's centre is on screen: XCTest fails the test ("Failed to
    /// determine hittability … Activation point invalid") for an element whose centre is off screen.
    func isHittableSafely(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty, windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        return element.isHittable
    }

    private var windowFrame: CGRect {
        app.windows.firstMatch.frame
    }

    /// The part of the screen where content can be tapped: below the navigation bars (a sheet's bar sits
    /// lower than the page's) and the bar pinned under them, above the home indicator, a floating search
    /// field and the bars pinned over the bottom of the content.
    private var contentArea: CGRect {
        let window = windowFrame
        var top = window.minY + 60
        for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && bar.frame.minY < 200 {
            top = max(top, bar.frame.maxY)
        }
        if let pinned = pinnedTopBarBottom(below: top) { top = pinned }
        var bottom = window.maxY - 34
        // The games list's floating search field covers the last rows (only when it is on screen).
        let search = app.searchFields.firstMatch
        if search.exists, search.frame.minY > window.maxY * 0.8, search.frame.maxY <= window.maxY, search.isHittable {
            bottom = search.frame.minY - 4
        }
        if let pinned = pinnedBottomBarTop { bottom = min(bottom, pinned) }
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    /// Buttons of the bars pinned over the bottom of the content (safe-area insets): New game's "Continue to
    /// film upload" and the roster page's save bars. A tap on content under them hits the bar instead.
    private static let pinnedBottomButtons = ["Continue to film upload", "Creating…", "Save roster", "Saving…",
                                              "Save & re-run analysis"]

    /// The top of a bar pinned over the bottom of the content, when one is on screen.
    private var pinnedBottomBarTop: CGFloat? {
        let window = windowFrame
        let buttons = app.buttons.matching(NSPredicate(format: "label IN %@", Self.pinnedBottomButtons)).allElementsBoundByIndex
        return buttons.compactMap { button -> CGFloat? in
            let frame = button.frame
            guard !frame.isEmpty, frame.minY > window.maxY * 0.4, frame.maxY <= window.maxY else { return nil }
            return frame.minY - 20
        }.min()
    }

    /// The bottom of the bar pinned under the navigation bar (the roster page's section picker).
    private func pinnedTopBarBottom(below top: CGFloat) -> CGFloat? {
        let picker = app.segmentedControls.firstMatch
        guard picker.exists else { return nil }
        let frame = picker.frame
        guard abs(frame.minY - top) < 24, frame.height < 80 else { return nil }
        return frame.maxY + 8
    }

    /// Content under a bar pinned over the bottom of the content: XCTest calls it hittable, but a tap there
    /// lands on the bar (New game's Continue, the roster's Save).
    func isUnderPinnedBar(_ element: XCUIElement) -> Bool {
        guard element.exists, !Self.pinnedBottomButtons.contains(element.label), let bar = pinnedBottomBarTop else { return false }
        return element.frame.midY > bar
    }

    /// Scrolls the main scrollable area until `element` can be tapped: by the distance its frame needs
    /// when it exists (into the middle of the screen), else in steps down then up (elements of lazy lists
    /// appear only once scrolled near).
    func scrollIntoView(_ element: XCUIElement, maxSwipes: Int = 10, up: Bool = false) {
        var blindDirection = up
        var blindSwipes = 0
        var lastY: CGFloat?
        var lastUp: Bool?
        var turns = 0
        for _ in 0..<(maxSwipes * 2) {
            if isVisible(element) { return }
            let frame = element.exists ? element.frame : .null
            if !frame.isNull, !frame.isEmpty, frame.minY > -20_000, frame.maxY < 20_000 {
                // The page did not move with the last swipe: its end is reached (or the element is not in the
                // page's scroll view): stop.
                if let lastY, abs(lastY - frame.minY) < 1 { return }
                lastY = frame.minY
                let area = contentArea
                let delta = frame.midY - area.midY
                // Back and forth around the middle: the element is on screen but something covers it (not
                // hittable); more scrolling does not help.
                let scrollsUp = delta < 0
                if let lastUp, lastUp != scrollsUp {
                    turns += 1
                    if turns >= 2 { return }
                }
                lastUp = scrollsUp
                let distance = min(max(abs(delta) / max(windowFrame.height, 1), 0.06), 0.55)
                scroll(up: scrollsUp, distance: distance)
            } else {
                scroll(up: blindDirection)
                blindSwipes += 1
                if blindSwipes == maxSwipes { blindDirection.toggle() }
                if blindSwipes >= maxSwipes * 2 { return }
            }
        }
    }

    /// Where scrolling drags run. Portrait: 14 pt into the page's left margin (16 pt), clear of the edge swipe
    /// (a vertical drag does not go back). Landscape: near the right edge, as a drag on the left (the safe
    /// area beside the camera) moves nothing there.
    private var dragX: CGFloat {
        let window = windowFrame
        guard window.width > 0 else { return 0.035 }
        return window.width > window.height ? 0.96 : 14 / window.width
    }

    /// One slow drag in the page's left margin (outside the cards, so it moves the page and not a list inside
    /// a card; away from the scroll indicator on the right, which a drag there grabs and scrubs): up shows
    /// what is above. A slow drag never taps what it starts on.
    func scroll(up: Bool = false, distance: CGFloat = 0.45) {
        let window = app.windows.firstMatch
        let height = max(window.frame.height, 1)
        // Start inside the content: not on a bar pinned over it (the roster's section picker and save bar,
        // New game's Continue), where the drag scrolls nothing.
        var area = contentArea
        let highest = max(0.15, (area.minY + 12) / height)
        var lowest = min(0.8, (area.maxY - 12) / height)
        // Never start a drag on the keyboard: sliding across its keys types a word ("loop", "org").
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            lowest = min(lowest, keyboard.frame.minY / height - 0.04)
            if lowest - highest < 0.2 {
                hideKeyboard()
                area = contentArea
                lowest = min(0.8, (area.maxY - 12) / height)
            }
        }
        let span = min(max(distance, 0.05), max(lowest - highest, 0.05))
        let from = up ? highest : lowest
        let to = up ? highest + span : lowest - span
        let x = dragX
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: from))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Scrolls to the top of the page.
    func scrollToTop() {
        for _ in 0..<12 { scroll(up: true, distance: 0.6) }
    }

    /// Pulls the list or page down to refresh.
    func pullToRefresh() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // MARK: Acting

    /// Taps `element` when it shows up within `timeout` (scrolling it into view first). It never taps an
    /// element the keyboard covers (the tap would type a key): it dismisses the keyboard first, and fails
    /// without tapping when it cannot.
    @discardableResult
    func tap(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("not on screen: \(element.description)", file: file, line: line)
            return false
        }
        if isUnderKeyboard(element) { hideKeyboard() }
        if !isHittableSafely(element) || isCutOff(element) || isUnderPinnedBar(element) {
            scrollIntoView(element)
            pause(0.4)  // a tap on a page still moving after the drag only stops it
        }
        if isUnderKeyboard(element) {
            hideKeyboard()
            if isUnderKeyboard(element) {
                XCTFail("the keyboard covers \(element.description); not tapping it", file: file, line: line)
                return false
            }
        }
        element.tap()
        return true
    }

    /// Taps the middle of the part of `element` that is on screen: the centre of a tall element (a game
    /// title over three lines at the largest text size) can be under the floating search field or below the
    /// screen.
    func tapVisiblePart(_ element: XCUIElement) {
        let frame = element.frame
        let visible = frame.intersection(contentArea)
        guard !visible.isNull, !visible.isEmpty, frame.width > 0, frame.height > 0 else {
            element.tap()
            return
        }
        let offset = CGVector(dx: (visible.midX - frame.minX) / frame.width, dy: (visible.midY - frame.minY) / frame.height)
        element.coordinate(withNormalizedOffset: offset).tap()
    }

    /// The software keyboard is up and covers part of `element`.
    func isUnderKeyboard(_ element: XCUIElement) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists, element.exists else { return false }
        let frame = element.frame
        let keys = keyboard.frame
        return !keys.isEmpty && frame.maxY > keys.minY + 1 && frame.minY < keys.maxY
    }

    /// The element straddles the edge of the content area (half under a bar or the floating search field).
    /// Elements wholly inside a bar (toolbar buttons) are not cut off.
    func isCutOff(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let area = contentArea
        let straddlesTop = frame.minY < area.minY - 0.5 && frame.maxY > area.minY + 0.5
        let straddlesBottom = frame.minY < area.maxY - 0.5 && frame.maxY > area.maxY + 0.5
        return (straddlesTop || straddlesBottom) && frame.height < area.height
    }

    /// Taps the button labelled `label` (exactly).
    @discardableResult
    func tapButton(_ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        tap(button(label), timeout: timeout, file: file, line: line)
    }

    /// Replaces the text of `field` with `text` ("" empties it) and checks the result. Unlike the shared
    /// driver's `replaceText`, it waits for the keyboard focus and moves the caret to the end before deleting
    /// (a tap leaves the caret where the finger was, so deleting from there left the start of a long address
    /// behind); it tries a second time when the field shows something else.
    func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 0..<2 {
            guard focus(field) else {
                XCTFail("\(field.description) did not get the keyboard", file: file, line: line)
                return
            }
            clearFocused(field)
            if !text.isEmpty { field.typeText(text) }
            pause(0.2)
            let value = (field.value as? String) ?? ""
            let done = text.isEmpty ? (value.isEmpty || value == field.placeholderValue) : value == text
            if done { return }
            if attempt == 1 {
                XCTFail("the field shows \"\(value)\" instead of \"\(text)\"", file: file, line: line)
            }
        }
    }

    /// Focuses `field` (the keyboard comes up for it) and empties it.
    func clear(_ field: XCUIElement) {
        guard focus(field) else { return }
        clearFocused(field)
    }

    /// Gives `field` the keyboard: scrolls it into view and above the keyboard, taps it, waits for the focus.
    @discardableResult
    func focus(_ field: XCUIElement) -> Bool {
        guard field.waitForExistence(timeout: 10) else { return false }
        if wait(field, until: "hasKeyboardFocus == true", 0.2) { return true }
        if isUnderKeyboard(field) { hideKeyboard() }
        if !isVisible(field) { scrollIntoView(field) }
        for _ in 0..<3 {
            revealAboveKeyboard(field)
            if isUnderKeyboard(field) { hideKeyboard() }
            if isUnderKeyboard(field) { return false }
            field.tap()
            if wait(field, until: "hasKeyboardFocus == true", 3) { return true }
            pause(0.5)
        }
        return false
    }

    /// Empties the focused `field`: the caret to the end (a tap at its right end), then deletes; Select All
    /// as a last resort.
    private func clearFocused(_ field: XCUIElement) {
        for attempt in 0..<5 {
            let current = (field.value as? String) ?? ""
            // An empty field reports its placeholder; a value equal to the placeholder ("coach") is deleted
            // once anyway (deleting in an empty field does nothing).
            if current.isEmpty || (attempt > 0 && current == field.placeholderValue) { return }
            if attempt == 0 {
                // A triple tap selects the whole line; Delete removes it.
                field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            } else if attempt < 4 {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            } else {
                field.press(forDuration: 1.2)
                let selectAll = app.menuItems["Select All"].firstMatch
                if selectAll.waitForExistence(timeout: 2) {
                    selectAll.tap()
                    field.typeText(XCUIKeyboardKey.delete.rawValue)
                }
            }
            pause(0.3)
        }
    }

    /// Moves `field` above the keyboard when the keyboard covers it (a tap there would hit a key).
    func revealAboveKeyboard(_ field: XCUIElement) {
        for _ in 0..<4 {
            guard isUnderKeyboard(field) else { return }
            let window = app.windows.firstMatch
            let x = dragX
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.45))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    /// Types into a secure field (its value never shows the text), only once the field has the keyboard.
    func typeSecure(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard focus(field) else {
            XCTFail("\(field.description) did not get the keyboard; nothing typed", file: file, line: line)
            return
        }
        field.typeText(text)
    }

    /// Goes back one screen (the navigation bar's first button).
    func back() {
        if app.keyboards.firstMatch.exists { hideKeyboard() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    /// Dismisses the keyboard: the keyboard's own dismiss key or a "Done" toolbar button when there is one,
    /// else a slow drag from the content down into the keyboard (the app's forms and lists dismiss the
    /// keyboard interactively).
    func hideKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        if app.toolbars.buttons["Done"].exists {
            app.toolbars.buttons["Done"].tap()
        } else if keyboard.buttons["Hide keyboard"].exists {
            keyboard.buttons["Hide keyboard"].tap()
        } else {
            let window = app.windows.firstMatch
            let top = keyboard.frame.minY / max(window.frame.height, 1)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: max(0.2, top - 0.25)))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.98))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        waitGone(keyboard, 3)
    }

    /// Taps somewhere neutral (the status bar strip) to close a menu or popover.
    func tapOutside() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
    }

    // MARK: Session

    /// Launches the app and makes sure it is signed in to the test server; ends on the games list. Like the
    /// shared driver's `launchSignedIn()`, but it types with `type(_:into:)` / `typeSecure`, which wait for
    /// the keyboard focus (the driver's typing sometimes starts before the focus arrives after a sign-out).
    func launchSignedIn(file: StaticString = #filePath, line: UInt = #line) {
        app.launch()
        let address = app.textFields["Server address"]
        driver.waitForAny([address, driver.gamesList], timeout: 30)
        if address.exists { signIn(file: file, line: line) }
        dismissSignInResult()
        XCTAssertTrue(driver.gamesList.waitForExistence(timeout: 30), "the games list did not appear after signing in",
                      file: file, line: line)
    }

    /// Fills in the sign-in form with the test server's address and account and signs in (accepting the
    /// one-time plain-http warning).
    func signIn(file: StaticString = #filePath, line: UInt = #line) {
        type(driver.server.origin, into: app.textFields["Server address"], file: file, line: line)
        let username = app.textFields["Username"]
        type(driver.server.username, into: username, file: file, line: line)
        // Return moves to the password (the form's "next") and Return there signs in (".go"): the password
        // field and "Sign in" are under the keyboard on iPhone, where a tap would type a key.
        username.typeText("\n")
        let password = app.secureTextFields["Password"]
        guard wait(password, until: "hasKeyboardFocus == true", 5) else {
            XCTFail("the password field did not get the keyboard; nothing typed", file: file, line: line)
            return
        }
        password.typeText(driver.server.password + "\n")
        let carryOn = app.alerts.buttons["Continue"].firstMatch
        let checking = buttonStarting("Checking the server")
        let result = app.navigationBars.buttons["Continue"].firstMatch
        let started = driver.waitForAny([carryOn, checking, result, driver.gamesList], timeout: 4)
        if started == nil, app.buttons["Sign in"].firstMatch.exists {
            // Return did not sign in: tap "Sign in" (tap() hides the keyboard first).
            shot("sign-in-not-started")
            tap(app.buttons["Sign in"].firstMatch, file: file, line: line)
        }
        if carryOn.waitForExistence(timeout: 4) { carryOn.tap() }
    }

    /// The sheet the app shows after a sign-in with something to say (demo server, warnings).
    func dismissSignInResult() {
        let carryOn = app.navigationBars.buttons["Continue"].firstMatch
        if carryOn.waitForExistence(timeout: 5) {
            shot("sign-in-result")
            carryOn.tap()
        }
    }

    /// Settings → "Sign Out" → confirm; ends on the sign-in screen. (The shared driver's `signOut()` looks
    /// for "Sign out", but the app's button says "Sign Out".)
    func signOut(file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["Settings"].firstMatch, file: file, line: line)
        let signOut = app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).firstMatch
        tap(signOut, file: file, line: line)
        // The confirmation's destructive button (the last hittable one).
        let confirm = app.alerts.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.tap()
        } else {
            app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).allElementsBoundByIndex.last { $0.isHittable }?.tap()
        }
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: 20), "sign-out did not show the sign-in screen",
                      file: file, line: line)
    }

    // MARK: Games list

    /// The games list row (cell) showing `title`.
    func gameRow(_ title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// Opens a game from the list by its title: scrolls to the row (rows off screen do not exist) and taps
    /// its title line (a tall row's centre can be off screen or under the floating search field).
    func openGame(titled title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = gameRow(title)
        if !row.waitForExistence(timeout: 15) { scrollIntoView(row) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no row for \(title)", file: file, line: line)
        let titleText = row.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex
            .min { $0.frame.height < $1.frame.height }
        let target = titleText ?? row
        let page = app.buttons["Game actions"].firstMatch
        for _ in 0..<2 {
            if !isVisible(target) { scrollIntoView(target) }
            tapVisiblePart(target)
            if page.waitForExistence(timeout: 10) { return }
            shot("game-did-not-open")
            if !target.exists { break }
        }
        XCTAssertTrue(page.exists, "the game page did not open", file: file, line: line)
    }

    // MARK: Game page

    /// Opens the iPhone "Game actions" menu and taps the item whose label begins with `item`.
    func gameAction(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        openGameActions(file: file, line: line)
        tap(buttonStarting(item), timeout: 5, file: file, line: line)
    }

    /// Opens the "Game actions" menu.
    func openGameActions(file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["Game actions"].firstMatch, file: file, line: line)
        XCTAssertTrue(buttonStarting("Roster & jerseys").waitForExistence(timeout: 5), "the Game actions menu did not open",
                      file: file, line: line)
    }

    /// Selects an analysis tab ("Box score", "Shot chart", …) from the scrolling pills.
    func selectTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.scrollViews["Analysis sections"].firstMatch
        let pill = row.buttons[title].firstMatch
        if !pill.waitForExistence(timeout: 3) { scrollIntoView(pill, maxSwipes: 12) }
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no \(title) tab", file: file, line: line)
        for _ in 0..<3 {
            if !isVisible(row) { scrollIntoView(row, maxSwipes: 12) }
            revealSideways(pill, in: row)
            if !isVisible(pill) { scrollIntoView(pill, maxSwipes: 12) }
            // Tap only a pill whose centre is on screen (XCTest fails the test for one off screen).
            let frame = pill.frame
            guard !frame.isEmpty, windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            pill.tap()
            if wait(pill, until: "selected == true", 3) { return }
        }
        XCTFail("the \(title) tab is not selected", file: file, line: line)
    }

    /// Drags the sideways `row` until `item` is inside it (the tab pills keep the selected tab in view, so the
    /// first pills can be far to the left).
    func revealSideways(_ item: XCUIElement, in row: XCUIElement) {
        for _ in 0..<10 {
            guard item.exists, row.exists else { return }
            let frame = item.frame
            let bounds = row.frame
            let inside = frame.width < bounds.width - 2
                ? frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
                : frame.midX > bounds.minX && frame.midX < bounds.maxX
            if inside { return }
            let toRight = frame.midX < bounds.midX
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: toRight ? 0.08 : 0.92, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: toRight ? 0.92 : 0.08, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }
}
#endif
