import AVFoundation
import CoreMedia
import CoreText
import CoreVideo
import XCTest

// Helpers for the iPad UI tests in this folder. Everything here is prefixed "iPad" because the UI test
// target is one Swift module shared with the iPhone tests. No player names: test data uses "Test Player N".

// MARK: - Driver

extension ScoutAppDriver {
    /// The first element whose label contains `text` (any type).
    func iPadAny(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first button whose label contains `text`.
    func iPadButton(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Rotates the simulator and lets the layout settle.
    func iPadRotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        iPadWait(1.5)
    }

    /// Lets the app run for `seconds` (animations, polling) without failing anything.
    func iPadWait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits until `element` exists and is hittable.
    @discardableResult
    func iPadWaitHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable { return true }
            iPadWait(0.25)
        } while Date() < deadline
        return false
    }

    /// Waits until `element` exists, is hittable and is enabled (a button the page enables after a refresh).
    @discardableResult
    func iPadWaitEnabled(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable, element.isEnabled { return true }
            iPadWait(0.25)
        } while Date() < deadline
        return false
    }

    /// Waits until `element` is gone.
    @discardableResult
    func iPadWaitGone(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            iPadWait(0.25)
        } while Date() < deadline
        return false
    }

    /// The sidebar row of the game whose title contains `title` (List rows are cells on iPad).
    func iPadGameRow(_ title: String) -> XCUIElement {
        let cell = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        return cell
    }

    /// Shows the sidebar when it is hidden (iPad portrait).
    func iPadShowSidebarIfHidden() {
        if gamesList.exists, gamesList.isHittable { return }
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
        if toggle.exists { toggle.tap() }
        iPadWait(1)
    }

    /// Opens a game from the sidebar and waits for its page header.
    @discardableResult
    func iPadOpenGame(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let row = iPadGameRow(title)
        guard row.waitForExistence(timeout: 20) else {
            XCTFail("no row for \(title)", file: file, line: line)
            return false
        }
        row.tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).element(boundBy: 1)
        _ = header.waitForExistence(timeout: 15)
        iPadWait(1.5)
        return true
    }

    /// The app's main window (the largest one).
    var iPadWindowFrame: CGRect {
        app.windows.allElementsBoundByIndex.map(\.frame).max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }

    /// Scrolls the game page (not the timeline inside it) by slow drags in the page's right margin, kept away
    /// from the window's top bar (a drag there moves the window on iPadOS) and from its corners.
    func iPadScrollPage(by points: CGFloat) {
        let window = iPadWindowFrame
        let x = window.maxX - 10
        let top = window.minY + 190
        let bottom = window.maxY - 130
        let span = max(bottom - top, 50)
        var remaining = points
        while abs(remaining) > 1 {
            let step = max(-span, min(span, remaining))
            let startY = step > 0 ? bottom : top
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: startY))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: startY - step))
            start.press(forDuration: 0.05, thenDragTo: end)
            remaining -= step
            iPadWait(0.6)
        }
    }

    /// iPadOS can leave the app in a smaller floating window (windowed multitasking); the tests expect the
    /// app to fill the screen. Uses the window controls when the window is smaller than the screen.
    func iPadEnsureFullScreen(_ testCase: XCTestCase) {
        // Compare areas: the screenshot is always in the device's portrait pixels.
        let screenshot = XCUIScreen.main.screenshot().image
        let screenArea = screenshot.size.width * screenshot.size.height
        let window = iPadWindowFrame
        guard screenArea > 0, window.width * window.height < screenArea * 0.9 else { return }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let attachment = XCTAttachment(string: springboard.debugDescription)
        attachment.name = "tree-springboard-small-window"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        XCTFail("The app window is smaller than the screen (\(window)); iPadOS windowed multitasking left it floating.")
    }

    /// Taps an analysis tab (pill or segment) by its title.
    func iPadSelectTab(_ title: String) {
        let tab = app.buttons[title].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() } else { XCTFail("no tab \(title)") }
        iPadWait(1.5)
    }

    /// Long-presses `element` to open its context menu.
    func iPadContextMenu(_ element: XCUIElement) {
        element.press(forDuration: 1.4)
        iPadWait(1)
    }

    /// The text field whose placeholder is `placeholder` (several of the app's fields have no label).
    func iPadField(placeholder: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    /// Launches signed in, in `orientation`, with the app filling the screen. A saved password signs in by
    /// itself, but the sign-in form shows for a moment first, so this waits for the games list before
    /// deciding to sign in (the driver's `launchSignedIn` can catch the form in that moment).
    func iPadLaunch(_ testCase: XCTestCase, orientation: UIDeviceOrientation = .landscapeLeft) {
        iPadRotate(orientation)
        app.launch()
        if !gamesList.waitForExistence(timeout: 20) {
            signIn()
            dismissSignInResultIfShown()
            XCTAssertTrue(gamesList.waitForExistence(timeout: 30), "the games list did not appear after signing in")
        }
        iPadEnsureFullScreen(testCase)
    }

    /// Replaces a field's text: taps at its end, deletes the characters one key at a time (a burst of Delete
    /// keys loses keys in fields that rewrite their text as it is typed, such as roster jersey cells), then
    /// types `text`.
    func iPadReplaceText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), file: file, line: line)
        field.tap()
        iPadWait(0.5)
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if current != placeholder, !current.isEmpty {
            // The caret lands where the field was tapped: move it to the end (⌘→ on the iPad's keyboard).
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            iPadWait(0.2)
            for _ in 0..<(current.count + 1) {
                field.typeText(XCUIKeyboardKey.delete.rawValue)
                iPadWait(0.25)
            }
        }
        field.typeText(text)
        iPadWait(0.3)
        XCTAssertEqual(field.value as? String, text, "the field did not take the typed text", file: file, line: line)
    }

    /// Hides the on-screen keyboard when it is up: Return ends editing of a single-line field. (The keyboard's
    /// own "Hide keyboard" key reports a frame outside the screen in landscape and cannot be tapped.)
    func iPadHideKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.typeText("\n")
        iPadWait(0.8)
    }

    /// The text fields of roster row `row` (1-based) in the iPad table, left to right: #, First name, Last name,
    /// FastScout name, Pos, Gr, Ht, Notes. The cells have no accessibility labels, so the row is found by its
    /// "Remove row N" button.
    func iPadRosterFields(row: Int) -> [XCUIElement] {
        let remove = app.buttons["Remove row \(row)"].firstMatch
        guard remove.waitForExistence(timeout: 10) else { return [] }
        let removeFrame = remove.frame
        return app.textFields.allElementsBoundByIndex
            .filter { field in
                let frame = field.frame
                return abs(frame.midY - removeFrame.midY) < 14 && frame.maxX <= removeFrame.minX + 2
            }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Taps the film picture shown in `frame` (aspect fit) at film pixel (`x`, `y`).
    func iPadTapPicture(in frame: XCUIElement, x: CGFloat, y: CGFloat, filmWidth: CGFloat = 640, filmHeight: CGFloat = 360) {
        let box = frame.frame
        let scale = min(box.width / filmWidth, box.height / filmHeight)
        let originX = box.minX + (box.width - filmWidth * scale) / 2
        let originY = box.minY + (box.height - filmHeight * scale) / 2
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: originX + x * scale, dy: originY + y * scale))
            .tap()
        iPadWait(0.8)
    }

    /// Picks `label` in the calibration sheet's "Landmark to tap" menu.
    func iPadChooseLandmark(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Landmark to tap'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no landmark picker", file: file, line: line)
        picker.tap()
        iPadWait(1)
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no landmark \(label) in the menu", file: file, line: line)
        item.tap()
        iPadWait(0.8)
    }

    /// Picks a file from "On My iPad" in the system Files picker the app presented.
    func iPadPickFile(_ cellIdentifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let onMyIPad = app.cells["DOC.sidebar.item.On My iPad"].firstMatch
        if onMyIPad.waitForExistence(timeout: 10), !onMyIPad.isSelected {
            onMyIPad.tap()
            iPadWait(1.5)
        }
        let cell = app.cells[cellIdentifier].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no \(cellIdentifier) in the Files picker", file: file, line: line)
        cell.tap()
        iPadWait(1.5)
    }

    /// The video items of the system Photos picker, left to right (the remote picker exposes them as images).
    func iPadPhotosItems(timeout: TimeInterval = 20) -> [XCUIElement] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let items = app.images.allElementsBoundByIndex
                .filter { $0.isHittable && $0.frame.width > 60 && $0.frame.width < 400 && $0.frame.height > 60 }
                .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            if !items.isEmpty { return items }
            iPadWait(0.5)
        } while Date() < deadline
        return []
    }

    /// Opens the game's roster page from its game page.
    func iPadOpenRoster(_ gameTitle: String) {
        iPadOpenGame(gameTitle)
        tapButton("Roster & jerseys")
        XCTAssertTrue(app.navigationBars["Rosters & jerseys"].waitForExistence(timeout: 15), "the roster page did not open")
        iPadWait(1.5)
    }

    /// Signs out through Settings (the app's button reads "Sign Out") and its confirmation.
    func iPadSignOut() {
        openSettings()
        let button = app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Sign Out button in Settings")
        button.tap()
        iPadWait(1)
        let confirm = app.buttons.matching(NSPredicate(format: "label ==[c] 'Sign out'")).allElementsBoundByIndex
            .last { $0.isHittable }
        confirm?.tap()
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: 20), "sign-out did not show the sign-in screen")
    }
}

// MARK: - Known bugs

extension XCTestCase {
    /// Records a known app bug as an expected failure and carries on with the test. (The driver sets
    /// `continueAfterFailure = false`, which would end the test at the expected failure and skip the steps after it.)
    @MainActor
    func iPadKnownBug(_ reason: String, strict: Bool = true, _ check: () -> Void) {
        let saved = continueAfterFailure
        continueAfterFailure = true
        let options = XCTExpectedFailure.Options()
        options.isStrict = strict
        XCTExpectFailure(reason, options: options) { check() }
        continueAfterFailure = saved
    }
}

// MARK: - Attachments

extension XCTestCase {
    /// Attaches the app's accessibility tree as text, to look up labels.
    @MainActor
    func iPadAttachTree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - Test server API

extension ScoutUITestAPI {
    func iPadGames() async throws -> [[String: Any]] {
        (try await send("GET", "/api/games") as? [[String: Any]]) ?? []
    }

    func iPadGame(_ gameID: String) async throws -> [String: Any] {
        (try await send("GET", "/api/games/\(gameID)") as? [String: Any]) ?? [:]
    }

    /// Deletes every game on the throwaway iPad test server (only test data lives there).
    func iPadDeleteAllGames() async {
        guard let games = try? await iPadGames() else { return }
        for game in games {
            if let id = game["id"] as? String { await deleteGame(id) }
        }
    }

    /// Uploads `film` in chunks of the session's size and completes it (analysis only with `autoStart`).
    func iPadUploadFilm(gameID: String, film: URL, autoStart: Bool) async throws {
        let data = try Data(contentsOf: film)
        let session = try await send("POST", "/api/games/\(gameID)/uploads", json: [
            "filename": film.lastPathComponent, "size": data.count, "content_type": "video/mp4",
        ]) as? [String: Any]
        guard let uploadID = session?["id"] as? String else { throw URLError(.cannotParseResponse) }
        let chunk = (session?["chunk_size"] as? Int) ?? 16 * 1024 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            try await send("PUT", "/api/uploads/\(uploadID)/chunk?offset=\(offset)", body: data.subdata(in: offset..<end))
            offset = end
        }
        try await send("POST", "/api/uploads/\(uploadID)/complete?auto_start=\(autoStart)", json: [String: Any]())
    }

    /// A game whose film is uploaded but not analysed (status "uploaded").
    func iPadUploadedGame(scoutedTeam: String, film: URL) async throws -> String {
        let id = try await createGame(scoutedTeam: scoutedTeam)
        try await iPadUploadFilm(gameID: id, film: film, autoStart: false)
        return id
    }

    /// A game with film and a finished analysis (mock server).
    func iPadAnalysedGame(scoutedTeam: String, film: URL, otherTeam: String = "Test Opponent") async throws -> String {
        let id = try await createGame(scoutedTeam: scoutedTeam, otherTeam: otherTeam)
        try await iPadUploadFilm(gameID: id, film: film, autoStart: true)
        try await waitForGame(id, status: ["ready"])
        return id
    }

    /// Starts a job ("analyze", "reanalyze", "report") and returns its id.
    @discardableResult
    func iPadStartJob(gameID: String, kind: String) async throws -> String {
        let job = try await send("POST", "/api/games/\(gameID)/jobs", json: ["kind": kind]) as? [String: Any]
        guard let id = job?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    func iPadJob(_ jobID: String) async throws -> [String: Any] {
        (try await send("GET", "/api/jobs/\(jobID)") as? [String: Any]) ?? [:]
    }

    /// Waits until the job's status is one of `statuses`.
    func iPadWaitForJob(_ jobID: String, status statuses: Set<String>, timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = try await iPadJob(jobID)["status"] as? String, statuses.contains(status) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "iPadTests", code: 0, userInfo: [NSLocalizedDescriptionKey: "job \(jobID) did not reach \(statuses)"])
    }

    /// Gives the game film by link (the mock server does not download it).
    func iPadSetVideoURL(gameID: String, url: String, autoStart: Bool) async throws {
        try await send("POST", "/api/games/\(gameID)/video-url?auto_start=\(autoStart)", json: ["url": url])
    }

    /// Replaces one roster ("scouted" / "other") with numbered test players.
    func iPadPutRoster(gameID: String, side: String, teamName: String, jerseys: [String]) async throws {
        let players: [[String: Any]] = jerseys.enumerated().map { index, jersey in
            ["jersey": jersey, "first_name": "Test", "last_name": "Player \(index + 1)"]
        }
        try await send("PUT", "/api/games/\(gameID)/rosters/\(side)", json: ["team_name": teamName, "players": players])
    }

    func iPadRoster(gameID: String, side: String) async throws -> [String: Any] {
        (try await send("GET", "/api/games/\(gameID)/rosters/\(side)") as? [String: Any]) ?? [:]
    }

    func iPadPatchGame(_ gameID: String, _ body: [String: Any]) async throws {
        try await send("PATCH", "/api/games/\(gameID)", json: body)
    }

    /// The jerseys of a roster, in the server's order.
    func iPadJerseys(gameID: String, side: String) async throws -> [String] {
        let players = (try await iPadRoster(gameID: gameID, side: side)["players"] as? [[String: Any]]) ?? []
        return players.compactMap { $0["jersey"] as? String }
    }

    /// The saved track overrides of a game.
    func iPadTrackOverrides(gameID: String) async throws -> [[String: Any]] {
        let state = try await send("GET", "/api/games/\(gameID)/tracks") as? [String: Any]
        return (state?["overrides"] as? [[String: Any]]) ?? []
    }

    /// The game's jobs, newest first.
    func iPadJobs(gameID: String) async throws -> [[String: Any]] {
        (try await send("GET", "/api/games/\(gameID)/jobs") as? [[String: Any]]) ?? []
    }

    /// Deletes every game whose scouted team is `team` (games a test created through the screens).
    func iPadDeleteGames(scoutedTeam team: String) async {
        for game in (try? await iPadGames()) ?? [] where (game["scouted_team"] as? String) == team {
            if let id = game["id"] as? String { await deleteGame(id) }
        }
    }
}

/// Seconds from the start of a timeline row's spoken label ("9 seconds, …", "1 minute, 4 seconds, …").
enum iPadSpokenClock {
    static func seconds(in label: String) -> Int? {
        var total = 0
        var matched = false
        let parts = label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts.prefix(3) {
            let words = part.split(separator: " ")
            guard words.count == 2, let value = Int(words[0]) else { break }
            switch words[1] {
            case "hour", "hours": total += value * 3600
            case "minute", "minutes": total += value * 60
            case "second", "seconds": total += value
            default: return matched ? total : nil
            }
            matched = true
        }
        return matched ? total : nil
    }
}

// MARK: - A ten-minute test film

/// A ten-minute film (as long as the mock server's synthetic game, so events and film line up): 640×360,
/// 2 fps, H.264, a court outline, a moving dot and the film's own clock ("m:ss") in big digits, so a
/// screenshot shows where the player is. No people. Written once per test run.
enum iPadLongFilm {
    static let width = 640
    static let height = 360
    static let framesPerSecond: Int32 = 2
    static let seconds = 600

    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-long-film.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-long-film-partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        try write(to: partial)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    private static func write(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 4],
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
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
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
        context.setFillColor(red: 0.78, green: 0.60, blue: 0.38, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(3)
        let court = CGRect(x: 30, y: 40, width: w - 60, height: h - 80)
        context.stroke(court)
        context.move(to: CGPoint(x: w / 2, y: court.minY))
        context.addLine(to: CGPoint(x: w / 2, y: court.maxY))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: w / 2 - 40, y: h / 2 - 40, width: 80, height: 80))
        for side in [court.minX, court.maxX - 110] {
            context.stroke(CGRect(x: side, y: h / 2 - 45, width: 110, height: 90))
        }
        let progress = CGFloat(index % 40) / 39
        context.setFillColor(red: 0.96, green: 0.50, blue: 0.15, alpha: 1)
        context.fillEllipse(in: CGRect(x: court.minX + progress * (court.width - 20), y: h / 2 - 10, width: 20, height: 20))
        // The film's clock, big and centred at the top.
        let second = index / Int(framesPerSecond)
        let clock = String(format: "%d:%02d", second / 60, second % 60)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
        let text = NSAttributedString(string: clock, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (w - bounds.width) / 2, y: h - 34)
        CTLineDraw(line, context)
        return buffer
    }
}
