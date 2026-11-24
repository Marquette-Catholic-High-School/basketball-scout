#if os(macOS)
import Foundation
import Testing
@testable import BasketballScout

/// The app's live captures (`LiveCaptureCenter`): one game at a time, the stream link in the Keychain only
/// while the capture can still be resumed, taking a capture up again after the app was quit, and the
/// "Live stream" form's checks before a capture starts.
@MainActor
struct LiveCaptureCenterTests {
    private static let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

    @MainActor
    private final class Harness {
        let gameID = "g_live00000001"
        let api = FakeLiveAPI(gameID: "g_live00000001")
        let launcher = FakeLiveLauncher()
        let sleeper = LiveTestSleeper()
        let keepAwake = FakeKeepAwake()
        let keychain = InMemoryKeychainStore()
        let root: ServiceTestFolder
        let server: ServerAddress
        let center: LiveCaptureCenter
        var statuses: [LiveStatus] = []

        init() throws {
            root = try ServiceTestFolder("LiveCenter")
            server = try ServerAddress(userInput: "https://scout.example.org")
            center = LiveCaptureCenter(
                linkStore: LiveLinkStore(keychain: keychain), launcher: launcher, sleeper: sleeper.sleeper,
                keepAwake: keepAwake, root: root.url, timing: LiveTestTiming.timing)
            center.apiProvider = { [unowned self] in api }
            center.serverProvider = { [unowned self] in server }
            center.onStatus = { [unowned self] in statuses.append($0) }
        }

        var link: LiveStreamLink {
            get throws { try LiveStreamLink(userInput: "rtmp://192.168.1.50/live/secretkey123") }
        }

        var savedLinks: [String] { keychain.items.values.sorted() }

        func process(_ index: Int = 0) async throws -> FakeLiveProcess {
            try await waitUntil("ffmpeg run \(index + 1)") { launcher.processes.count > index }
            return launcher.processes[index]
        }

        func cleanUp() { root.remove() }
    }

    @Test func aCaptureRemembersItsLinkUntilTheGameIsOver() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        #expect(!h.center.isCapturing)

        let capture = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        let process = try await h.process()

        #expect(h.center.isCapturing)
        #expect(h.center.controller(for: h.gameID) === capture)
        #expect(h.center.active === capture)
        #expect(process.inputLink == "rtmp://192.168.1.50/live/secretkey123")
        #expect(process.directory.lastPathComponent == h.gameID)
        // In the Keychain (and nowhere else), under the server and the game.
        #expect(h.savedLinks == ["rtmp://192.168.1.50/live/secretkey123"])
        #expect(h.keychain.items.keys.first?.account == "https://scout.example.org|\(h.gameID)")
        #expect(h.statuses.count == 1)

        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        capture.end()
        try await waitUntil("the link forgotten") { h.savedLinks.isEmpty }

        #expect(capture.phase == .ended(.finished))
        #expect(!h.center.isCapturing)
        // Its panel stays on the page until the coach dismisses it.
        #expect(h.center.controller(for: h.gameID) === capture)
        h.center.dismiss(gameID: h.gameID)
        #expect(h.center.controller(for: h.gameID) == nil)
    }

    @Test func aRefusedStartLeavesNothingBehind() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.api.fail(.start, with: FakeLiveAPI.serverError(409, code: ErrorCode.conflict, title: "Conflict"))

        await #expect(throws: APIError.self) {
            try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        }

        #expect(h.center.controller(for: h.gameID) == nil)
        #expect(!h.center.isCapturing)
        #expect(h.savedLinks.isEmpty)
        #expect(h.launcher.processes.isEmpty)
    }

    @Test func onlyOneGameIsCapturedAtATime() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let capture = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        _ = try await h.process()

        await #expect(throws: LiveCaptureCenterError.anotherCapture) {
            try await h.center.start(gameID: "g_other0000002", link: try h.link, ffmpeg: Self.ffmpeg)
        }
        #expect(h.center.isCapturingAnotherGame(than: "g_other0000002"))
        #expect(!h.center.isCapturingAnotherGame(than: h.gameID))
        // Starting the same game again is the same capture, not a second ffmpeg.
        #expect(try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg) === capture)
        #expect(h.launcher.processes.count == 1)
        #expect(LiveCaptureCenterError.anotherCapture.title == "Another live game is being captured on this Mac")

        await h.center.suspendAll()
        #expect(!h.center.isCapturing)
    }

    @Test func quittingKeepsTheLinkAndThePartsSoTheCaptureCanBeResumed() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let capture = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        let process = try await h.process()
        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        // The network goes away, two more parts are recorded, then the app is quit.
        h.api.fail(.create, with: FakeLiveAPI.offline)
        h.sleeper.hold(.seconds(1))
        try process.finishPart(1)
        try process.finishPart(2)
        try await waitUntil("two parts waiting") { capture.partsWaiting == 2 }

        await h.center.suspendAll()

        #expect(capture.phase == .ended(.stopped))
        #expect(process.interrupts == 1)
        #expect(h.api.count(.finish) == 0)
        #expect(h.savedLinks.count == 1)
        let left = await h.center.leftovers(for: h.gameID, stillCapturing: true)
        #expect(left.pendingParts == 2 && left.hasLink)
        #expect(left.folder?.lastPathComponent == h.gameID)
        #expect(!left.isEmpty)

        // The next launch: another center on the same folder and Keychain.
        let relaunched = LiveCaptureCenter(
            linkStore: LiveLinkStore(keychain: h.keychain), launcher: h.launcher, sleeper: LiveTestSleeper().sleeper,
            keepAwake: h.keepAwake, root: h.root.url, timing: LiveTestTiming.timing)
        relaunched.apiProvider = { [api = h.api] in api }
        relaunched.serverProvider = { [server = h.server] in server }
        #expect(relaunched.controller(for: h.gameID) == nil)
        #expect(await relaunched.leftovers(for: h.gameID, stillCapturing: true) == left)

        let resumed = try await relaunched.resume(gameID: h.gameID, ffmpeg: Self.ffmpeg)
        let second = try await h.process(1)

        // The parts that waited are sent first; ffmpeg numbers on with the link from the Keychain.
        try await waitUntil("the waiting parts on the server") { resumed.partsSent == 2 }
        #expect(h.api.parts.keys.sorted() == [0, 1, 2])
        #expect(second.startNumber == 3)
        #expect(second.inputLink == "rtmp://192.168.1.50/live/secretkey123")
        await relaunched.suspendAll()
    }

    @Test func leftoverPartsCanBeSentWithoutTheLink() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let folder = h.center.folder(for: h.gameID)
        try folder.create()
        let earlier = FakeLiveProcess(
            arguments: ["-segment_list", folder.fileURL("parts-0.csv").path(percentEncoded: false)], directory: folder.url)
        try earlier.finishPart(0)
        let left = await h.center.leftovers(for: h.gameID, stillCapturing: true)
        #expect(left.pendingParts == 1 && !left.hasLink)

        // Without the link there is nothing to resume, and the message does not pretend otherwise.
        await #expect(throws: LiveCaptureCenterError.linkForgotten) {
            try await h.center.resume(gameID: h.gameID, ffmpeg: Self.ffmpeg)
        }
        let sending = try await h.center.sendLeftovers(gameID: h.gameID)
        try await waitUntil("the capture to end") { !sending.isActive }

        #expect(h.api.parts.keys.sorted() == [0])
        #expect(h.launcher.processes.isEmpty)
        #expect(sending.phase == .ended(.stopped))
        let after = await h.center.leftovers(for: h.gameID, stillCapturing: true)
        #expect(after.pendingParts == 0)
    }

    @Test func aGameThatNoLongerTakesFilmHasNoUseForItsLink() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let capture = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        let process = try await h.process()
        h.api.stopTakingFilm(.ended, reason: .idle)

        try process.finishPart(0)
        try await waitUntil("the capture to end") { !capture.isActive }
        try await waitUntil("the link forgotten") { h.savedLinks.isEmpty }

        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(capture.serverEndReason == .idle)
        // The part that was not sent is still there, and the panel says where.
        #expect(capture.partsWaiting == 1)
        #expect(capture.folder.exists)

        // A link left by a capture that never got to forget it (a crash) goes when the game is seen ended.
        LiveLinkStore(keychain: h.keychain).save(try h.link, gameID: "g_gone00000003", server: h.server)
        let left = await h.center.leftovers(for: "g_gone00000003", stillCapturing: false)
        #expect(left.isEmpty)
        #expect(h.savedLinks.isEmpty)
    }

    @Test func signingOutStopsTheCaptureWithoutEndingTheGame() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let capture = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        let process = try await h.process()

        h.center.reset()
        try await waitUntil("the capture to stop") { !capture.isActive }

        #expect(process.interrupts == 1)
        #expect(capture.phase == .ended(.stopped))
        #expect(h.center.controller(for: h.gameID) == nil)
        #expect(h.api.count(.finish) == 0)
    }

    // MARK: - The "Live stream" form

    private func session() -> ServerSession {
        ServerSession.preview(state: .signedIn)
    }

    @Test func theFormChecksTheLinkBeforeAnythingIsSent() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let model = LiveStartModel(
            gameID: h.gameID, captures: h.center, session: session(),
            locator: LiveFFmpegLocator(defaults: UserDefaults(suiteName: "LiveStart.\(UUID().uuidString)") ?? .standard) { _ in true })

        await model.start()
        #expect(model.error?.title == "Stream link needed")

        model.linkText = "www.example.org/stream"
        await model.start()
        #expect(model.error?.title == "Check the stream link")
        #expect(model.error?.message.contains("example.org") == false)  // the link is never repeated
        #expect(h.api.calls.isEmpty && h.launcher.processes.isEmpty)
        #expect(!model.didStart && !model.needsFFmpeg)
    }

    @Test func withoutFFmpegTheFormSaysHowToGetItAndStartsNothing() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        var installed = false
        let defaults = UserDefaults(suiteName: "LiveStart.\(UUID().uuidString)") ?? .standard
        let model = LiveStartModel(
            gameID: h.gameID, captures: h.center, session: session(),
            locator: LiveFFmpegLocator(defaults: defaults) { path in installed && path == "/opt/homebrew/bin/ffmpeg" || path == "/Applications/ffmpeg" })
        model.linkText = "rtmp://192.168.1.50/live"

        await model.start()
        #expect(model.needsFFmpeg)
        #expect(model.error == nil)
        #expect(h.api.calls.isEmpty)
        #expect(LiveText.ffmpegInstallCommand == "brew install ffmpeg")

        // "Check again" before it is installed changes nothing; a file that cannot be run is refused.
        model.checkForFFmpeg()
        #expect(model.needsFFmpeg)
        model.choseFFmpeg(URL(fileURLWithPath: "/Applications/Notes.txt"))
        #expect(model.error?.title == "That file can't be run")
        #expect(model.needsFFmpeg)

        // "Choose ffmpeg…" with a program: remembered, and the notice goes.
        model.choseFFmpeg(URL(fileURLWithPath: "/Applications/ffmpeg"))
        #expect(!model.needsFFmpeg && model.error == nil)
        #expect(defaults.string(forKey: LiveFFmpegLocator.defaultsKey) == "/Applications/ffmpeg")

        // Or installed with Homebrew, then "Check again".
        installed = true
        model.checkForFFmpeg()
        #expect(!model.needsFFmpeg)

        await model.start()
        let process = try await h.process()
        #expect(model.didStart)
        #expect(model.linkText.isEmpty)  // the link does not stay in the field
        #expect(h.launcher.executables.first?.path(percentEncoded: false) == "/opt/homebrew/bin/ffmpeg")
        #expect(process.inputLink == "rtmp://192.168.1.50/live")
        await h.center.suspendAll()
    }

    @Test func aStartTheServerRefusesShowsUnderTheFieldAndKeepsTheLink() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.api.fail(.start, with: FakeLiveAPI.serverError(409, code: ErrorCode.conflict, title: "Conflict"))
        let model = LiveStartModel(
            gameID: h.gameID, captures: h.center, session: session(),
            locator: LiveFFmpegLocator(defaults: UserDefaults(suiteName: "LiveStart.\(UUID().uuidString)") ?? .standard) { _ in true })
        model.linkText = "rtmp://192.168.1.50/live"

        await model.start()

        #expect(model.error?.title == "Conflict")
        #expect(!model.didStart && !model.isStarting)
        #expect(model.linkText == "rtmp://192.168.1.50/live")
        #expect(model.canStart)
    }

    @Test func theFormWaitsWhileAnotherGameIsCaptured() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        _ = try await h.center.start(gameID: h.gameID, link: try h.link, ffmpeg: Self.ffmpeg)
        _ = try await h.process()
        let model = LiveStartModel(
            gameID: "g_other0000002", captures: h.center, session: session(),
            locator: LiveFFmpegLocator(defaults: UserDefaults(suiteName: "LiveStart.\(UUID().uuidString)") ?? .standard) { _ in true })
        model.linkText = "rtmp://192.168.1.51/live"

        #expect(model.anotherCaptureIsRunning && !model.canStart)
        await model.start()
        #expect(h.api.count(.start) == 1)
        #expect(!model.didStart)
        await h.center.suspendAll()
    }
}
#endif
