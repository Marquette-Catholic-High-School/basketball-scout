import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

/// Drives the app for one UI test: launch, sign in, find things, take screenshots.
///
/// Elements are found by their visible labels (the app has no test-only identifiers), so a test also
/// checks the wording a coach sees.
@MainActor
final class ScoutAppDriver {
    let app: XCUIApplication
    let server: ScoutUITestServer
    let api: ScoutUITestAPI
    private unowned let testCase: XCTestCase
    private var shotNumber = 0

    init(_ testCase: XCTestCase) throws {
        self.testCase = testCase
        server = try ScoutUITestServer.fromEnvironment()
        api = ScoutUITestAPI(server: server)
        app = XCUIApplication()
        testCase.continueAfterFailure = false
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: Launch and sign-in

    /// Launches the app and makes sure it is signed in to the test server (signing out of any other
    /// session first). Ends on the games list.
    func launchSignedIn() {
        app.launch()
        let address = app.textFields["Server address"]
        let games = gamesList
        let appeared = waitForAny([address, games], timeout: 30)
        if appeared == games, !isSignedInToTestServer() {
            signOut()
        }
        if address.exists || address.waitForExistence(timeout: 2) {
            signIn()
        }
        dismissSignInResultIfShown()
        XCTAssertTrue(gamesList.waitForExistence(timeout: 30), "the games list did not appear after signing in")
    }

    /// The games list (iPhone: first screen; iPad/Mac: sidebar).
    var gamesList: XCUIElement {
        app.navigationBars["Games"].firstMatch
    }

    /// Fills in the sign-in form and signs in.
    func signIn() {
        let address = app.textFields["Server address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "no Server address field")
        replaceText(in: address, with: server.origin)
        let username = app.textFields["Username"]
        replaceText(in: username, with: server.username)
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText(server.password)
        tapButton("Sign in")
        // Plain http to a local test server: the one-time warning, when the app shows it.
        let carryOn = app.buttons["Continue"]
        if carryOn.waitForExistence(timeout: 3), !gamesList.exists {
            carryOn.tap()
        }
    }

    /// The sheet the app shows after a sign-in with something to say (demo server, warnings).
    func dismissSignInResultIfShown() {
        let carryOn = app.buttons["Continue"]
        if carryOn.waitForExistence(timeout: 4) {
            snapshot("sign-in result")
            carryOn.tap()
        }
    }

    private func isSignedInToTestServer() -> Bool {
        // The app keeps one server; the test server is the only one these tests use.
        true
    }

    /// Opens Settings and signs out (confirming).
    func signOut() {
        openSettings()
        let signOut = app.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "no Sign out button in Settings")
        signOut.tap()
        // The confirmation's destructive button.
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign out'")).allElementsBoundByIndex
            .last { $0.isHittable }
        confirm?.tap()
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: 20), "sign-out did not show the sign-in screen")
    }

    func openSettings() {
        tapButton("Settings")
    }

    // MARK: Elements

    /// Waits for the first of `elements` to exist and returns it (nil after `timeout`).
    @discardableResult
    func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = elements.first(where: \.exists) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return nil
    }

    /// Taps the first hittable button whose label is `label` (waits for it).
    func tapButton(_ label: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "no button \"\(label)\"", file: file, line: line)
        button.tap()
    }

    /// Asserts that some element shows `text` (static text, button or other), waiting up to `timeout`.
    func expectText(_ text: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "\"\(text)\" is not on screen", file: file, line: line)
    }

    /// Clears `field` and types `text` instead. An empty field reports its placeholder as its value, so a
    /// few extra deletes are sent (harmless); when the caret landed inside the text, Select All clears it.
    func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 3))
        }
        if let left = field.value as? String, !left.isEmpty, left != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"].firstMatch
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "the field did not take the typed text")
    }

    // MARK: Screenshots

    /// Attaches a screenshot of the whole screen to the test result (kept always), numbered in order.
    func snapshot(_ name: String) {
        shotNumber += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = isPad ? "iPad" : "iPhone"
        attachment.name = String(format: "%@-%02d-%@", device, shotNumber, name)
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    // MARK: Test data

    /// A game created through the API, its film uploaded and analysed (mock server: about 10 s).
    func analysedGame(scoutedTeam: String) async throws -> String {
        let id = try await api.createGame(scoutedTeam: scoutedTeam)
        let film = try ScoutUITestFilm.url()
        try await api.uploadFilm(gameID: id, film: film)
        try await api.waitForGame(id, status: ["ready"])
        return id
    }
}

/// A short test film written at test time (the repository keeps no film files): 640×360, 12 seconds at
/// 15 fps, H.264. Each frame shows a plain court outline on a wood-coloured floor and a moving dot, so the
/// player, the timeline and the calibration screen have something to show. No people.
enum ScoutUITestFilm {
    static let width = 640
    static let height = 360
    static let framesPerSecond: Int32 = 15
    static let seconds = 12

    /// The film's file, written once per test run.
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-film.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try write(to: url)
        return url
    }

    private static func write(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int(framesPerSecond) * seconds
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let buffer = try frame(index, of: frameCount)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func frame(_ index: Int, of count: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
            == kCVReturnSuccess, let buffer = created
        else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(red: 0.78, green: 0.60, blue: 0.38, alpha: 1)   // floor
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(3)
        let court = CGRect(x: 30, y: 40, width: w - 60, height: h - 80)
        context.stroke(court)
        context.move(to: CGPoint(x: w / 2, y: court.minY))                     // half-court line
        context.addLine(to: CGPoint(x: w / 2, y: court.maxY))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: w / 2 - 40, y: h / 2 - 40, width: 80, height: 80))
        for side in [court.minX, court.maxX - 110] {                            // lanes
            context.stroke(CGRect(x: side, y: h / 2 - 45, width: 110, height: 90))
        }
        let progress = CGFloat(index) / CGFloat(max(count - 1, 1))            // a moving ball
        context.setFillColor(red: 0.96, green: 0.50, blue: 0.15, alpha: 1)
        context.fillEllipse(in: CGRect(x: court.minX + progress * (court.width - 20), y: h / 2 - 10 + 60 * sin(progress * 12), width: 20, height: 20))
        return buffer
    }
}
