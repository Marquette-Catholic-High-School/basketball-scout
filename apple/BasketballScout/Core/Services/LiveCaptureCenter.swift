#if os(macOS)
import Foundation
import Observation

/// What an earlier capture of a game left on this Mac (the app was quit, or crashed, in the middle).
nonisolated struct LiveLeftovers: Hashable, Sendable {
    /// Finished parts in the game's folder that were never sent.
    var pendingParts = 0
    /// The stream link is still in the Keychain, so the capture can be resumed without pasting it again.
    var hasLink = false
    /// The game's folder, when it exists.
    var folder: URL?

    var isEmpty: Bool { pendingParts == 0 && !hasLink }
}

/// Why a capture was not started.
nonisolated enum LiveCaptureCenterError: PresentableError, Hashable, Sendable {
    /// Another game is being captured on this Mac.
    case anotherCapture
    /// The stream link of this game is no longer in the Keychain.
    case linkForgotten

    var title: String {
        switch self {
        case .anotherCapture: "Another live game is being captured on this Mac"
        case .linkForgotten: "The stream link is not saved any more"
        }
    }

    var message: String {
        switch self {
        case .anotherCapture: "End that game before you start a new one."
        case .linkForgotten: "This Mac no longer has the stream link of this game."
        }
    }

    var hint: String? {
        switch self {
        case .anotherCapture: nil
        case .linkForgotten: "The parts that are waiting can still be sent."
        }
    }
}

/// The Mac's live captures, owned by the app (`AppModel.liveCapture`) so a capture carries on while the
/// coach looks at other games or closes the window. One game is captured at a time.
///
/// It makes the `LiveCaptureController` of a game with the app's parts, remembers the game's stream link in
/// the Keychain while the capture can still be resumed (`LiveLinkStore`), and stops ffmpeg cleanly when the
/// app quits. Parts wait in `Library/Application Support/Basketball Scout/LiveCapture/<game id>/` until the
/// server has them.
@Observable
final class LiveCaptureCenter {
    /// The captures of this run of the app, by game id: the running one, and ended ones until dismissed.
    private(set) var controllers: [String: LiveCaptureController] = [:]

    /// The signed-in server (set by `AppModel`); nil while signed out or locked out.
    @ObservationIgnored var apiProvider: () -> (any LiveCaptureAPI)? = { nil }
    /// The server's address, which the stream links are filed under in the Keychain.
    @ObservationIgnored var serverProvider: () -> ServerAddress? = { nil }
    /// Errors that stop every request go to the session's lockout gate, with the client that got them.
    @ObservationIgnored var errorReporter: (any Error, any LiveCaptureAPI) -> Void = { _, _ in }
    /// A live status the server answered a capture with: the games list and the open game page show it.
    @ObservationIgnored var onStatus: (LiveStatus) -> Void = { _ in }

    @ObservationIgnored private let linkStore: LiveLinkStore
    @ObservationIgnored private let launcher: any LiveProcessLauncher
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let keepAwake: any LiveKeepAwake
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let timing: LiveCaptureTiming

    /// - Parameters:
    ///   - linkStore: where stream links are remembered (tests pass an in-memory Keychain).
    ///   - launcher: starts ffmpeg (tests pass a fake).
    ///   - root: the folder that holds a folder per captured game.
    init(
        linkStore: LiveLinkStore = .standard,
        launcher: any LiveProcessLauncher = SystemLiveProcessLauncher(),
        sleeper: Sleeper = .live,
        keepAwake: any LiveKeepAwake = SystemLiveKeepAwake(),
        root: URL = LiveCaptureFolder.standardRoot(),
        timing: LiveCaptureTiming = .standard
    ) {
        self.linkStore = linkStore
        self.launcher = launcher
        self.sleeper = sleeper
        self.keepAwake = keepAwake
        self.root = root
        self.timing = timing
    }

    // MARK: - Reading

    /// The capture of `gameID` on this Mac: running, or ended and not dismissed yet.
    func controller(for gameID: String) -> LiveCaptureController? {
        controllers[gameID]
    }

    /// The capture that is running, if any.
    var active: LiveCaptureController? {
        controllers.values.first { $0.isActive }
    }

    /// A game is being captured (ask before quitting).
    var isCapturing: Bool { active != nil }

    /// Another game than `gameID` is being captured.
    func isCapturingAnotherGame(than gameID: String) -> Bool {
        active.map { $0.gameID != gameID } ?? false
    }

    /// The folder that holds `gameID`'s parts.
    func folder(for gameID: String) -> LiveCaptureFolder {
        LiveCaptureFolder(gameID: gameID, root: root)
    }

    /// What an earlier capture of `gameID` left on this Mac. `stillCapturing`: the game still takes film; a
    /// game that does not has no use for its stream link any more, so the link is forgotten.
    func leftovers(for gameID: String, stillCapturing: Bool) async -> LiveLeftovers {
        let folder = folder(for: gameID)
        let pending = await Self.pendingParts(in: folder)
        var hasLink = false
        if let server = serverProvider() {
            if stillCapturing {
                hasLink = linkStore.link(gameID: gameID, server: server) != nil
            } else if controllers[gameID]?.isActive != true {
                linkStore.remove(gameID: gameID, server: server)
            }
        }
        return LiveLeftovers(pendingParts: pending, hasLink: hasLink, folder: folder.exists ? folder.url : nil)
    }

    @concurrent
    private nonisolated static func pendingParts(in folder: LiveCaptureFolder) async -> Int {
        folder.snapshot(fallbackDuration: 120).pending.count
    }

    // MARK: - Starting

    /// Starts capturing `gameID` from `link` with the ffmpeg at `ffmpeg`. Returns once the server made the
    /// game live and ffmpeg is being started; throws what the server answered when it refuses.
    @discardableResult
    func start(gameID: String, link: LiveStreamLink, ffmpeg: URL) async throws -> LiveCaptureController {
        try await begin(gameID: gameID, mode: .capture(link: link, ffmpeg: ffmpeg), remember: link)
    }

    /// Takes up the capture of `gameID` again after the app was quit: the stream link comes from the
    /// Keychain, the parts still on this Mac are sent first, and ffmpeg carries on with the next part number.
    @discardableResult
    func resume(gameID: String, ffmpeg: URL) async throws -> LiveCaptureController {
        guard let server = serverProvider(), let link = linkStore.link(gameID: gameID, server: server) else {
            throw LiveCaptureCenterError.linkForgotten
        }
        return try await begin(gameID: gameID, mode: .capture(link: link, ffmpeg: ffmpeg), remember: nil)
    }

    /// Sends the finished parts of `gameID` that are still on this Mac, without reading the stream.
    @discardableResult
    func sendLeftovers(gameID: String) async throws -> LiveCaptureController {
        try await begin(gameID: gameID, mode: .sendOnly, remember: nil)
    }

    private func begin(gameID: String, mode: LiveCaptureController.Mode, remember link: LiveStreamLink?) async throws -> LiveCaptureController {
        if let running = active {
            if running.gameID == gameID { return running }
            throw LiveCaptureCenterError.anotherCapture
        }
        let controller = LiveCaptureController(
            gameID: gameID, mode: mode, folder: folder(for: gameID),
            dependencies: LiveCaptureDependencies(
                api: { [weak self] in self?.apiProvider() },
                launcher: launcher,
                sleeper: sleeper,
                keepAwake: keepAwake,
                reportError: { [weak self] error, api in self?.errorReporter(error, api) },
                statusChanged: { [weak self] status in self?.onStatus(status) },
                timing: timing))
        controllers[gameID] = controller
        do {
            try await controller.start()
        } catch {
            // Kept on screen only when it has something to say about parts that are still on this Mac.
            if controller.partsWaiting == 0 { controllers[gameID] = nil }
            forgetLinkIfOver(controller)
            throw error
        }
        if let link, let server = serverProvider() {
            linkStore.save(link, gameID: gameID, server: server)
        }
        Task { [weak self] in
            await controller.waitUntilEnded()
            self?.forgetLinkIfOver(controller)
        }
        return controller
    }

    /// The link is kept only while the capture can be resumed: not once the game is over for this Mac.
    private func forgetLinkIfOver(_ controller: LiveCaptureController) {
        guard case .ended(let ending) = controller.phase, ending == .finished || ending == .noLongerTakesFilm,
              let server = serverProvider()
        else { return }
        linkStore.remove(gameID: controller.gameID, server: server)
    }

    // MARK: - Ending

    /// Takes an ended capture off the game page ("Done").
    func dismiss(gameID: String) {
        guard let controller = controllers[gameID], !controller.isActive else { return }
        controllers[gameID] = nil
    }

    /// Stops every capture without ending its game and waits for ffmpeg to close its last part (the app is
    /// quitting, the coach signed out or changed the server). The parts and the stream link stay, so the
    /// capture can be resumed.
    func suspendAll() async {
        for controller in controllers.values where controller.isActive {
            await controller.suspend()
        }
    }

    /// The app is terminating now: interrupts ffmpeg without waiting for it.
    func interruptAll() {
        for controller in controllers.values where controller.isActive {
            controller.interruptNow()
        }
    }

    /// Forgets the captures of another server (sign-out, another server): running ones are stopped first.
    func reset() {
        let running = controllers.values.filter(\.isActive)
        controllers = [:]
        guard !running.isEmpty else { return }
        Task {
            for controller in running { await controller.suspend() }
        }
    }
}
#endif
