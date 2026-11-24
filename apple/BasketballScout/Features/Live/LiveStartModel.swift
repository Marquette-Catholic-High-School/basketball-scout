#if os(macOS)
import Foundation
import Observation

/// "Live stream" on the film screen (Mac): the stream link the coach pastes, the checks before a capture
/// starts (the link reads as a stream, ffmpeg is on this Mac, no other game is being captured) and the start
/// itself. The link is a secret: it stays in this field until the capture has it, is never part of an error
/// text, and is cleared once the capture started.
@Observable
final class LiveStartModel {
    let gameID: String
    /// The "Stream link" field.
    var linkText = ""
    /// What kept the capture from starting (a link that is not a stream, the server's refusal).
    private(set) var error: (any PresentableError)?
    /// ffmpeg was not found: the form shows how to get it.
    private(set) var needsFFmpeg = false
    private(set) var isStarting = false
    /// The capture started: the film screen makes way for the game page.
    private(set) var didStart = false

    @ObservationIgnored private let captures: LiveCaptureCenter
    @ObservationIgnored private let session: ServerSession
    @ObservationIgnored private let locator: LiveFFmpegLocator

    init(gameID: String, captures: LiveCaptureCenter, session: ServerSession, locator: LiveFFmpegLocator = LiveFFmpegLocator()) {
        self.gameID = gameID
        self.captures = captures
        self.session = session
        self.locator = locator
    }

    /// Another game is being captured on this Mac (one at a time).
    var anotherCaptureIsRunning: Bool {
        captures.isCapturingAnotherGame(than: gameID)
    }

    var canStart: Bool { !isStarting && !didStart && !anotherCaptureIsRunning }

    /// "Start live game": checks the link, looks for ffmpeg, then asks the server to make the game live and
    /// starts the capture. What the server answers when it refuses is shown under the field.
    func start() async {
        guard canStart else { return }
        error = nil
        let link: LiveStreamLink
        do {
            link = try LiveStreamLink(userInput: linkText)
        } catch {
            self.error = error
            return
        }
        guard let ffmpeg = locator.find() else {
            needsFFmpeg = true
            return
        }
        needsFFmpeg = false
        isStarting = true
        defer { isStarting = false }
        let client = session.client
        do {
            try await captures.start(gameID: gameID, link: link, ffmpeg: ffmpeg)
            linkText = ""
            didStart = true
        } catch {
            self.error = session.report(error, from: client)
        }
    }

    /// "Check again", after ffmpeg was installed.
    func checkForFFmpeg() {
        needsFFmpeg = locator.find() == nil
    }

    /// A file chosen with "Choose ffmpeg…": remembered when it can be run.
    func choseFFmpeg(_ file: URL) {
        if locator.remember(file) {
            error = nil
            needsFFmpeg = locator.find() == nil
        } else {
            error = LiveText.notAProgram
        }
    }
}
#endif
