#if os(macOS)
import Foundation
import Observation

/// How long a live capture waits between its steps. Tests pass their own, so every wait can be told apart.
nonisolated struct LiveCaptureTiming: Sendable {
    /// How often ffmpeg's list of finished parts is read.
    var listPoll: Duration = .seconds(1)
    /// How long ffmpeg gets to close its last part after the interrupt before it is killed.
    var exitGrace: Duration = .seconds(10)
    /// How often a capture that waits for the coach to sign in again looks for the session.
    var signInCheck: Duration = .seconds(5)
    /// How soon after the start the game's live state is read for the first time (a server without a GPU
    /// fails the live job within a second or two).
    var firstStatusCheck: Duration = .seconds(3)
    /// How often it is read after that (the game page's rate).
    var statusCheck: Duration = LivePollRule.interval
    /// The pause before ffmpeg is started again, by how many runs in a row brought no part.
    var reconnectDelay: @Sendable (Int) -> Duration = LiveCaptureTiming.standardReconnectDelay
    /// The wait before sending is tried again, by how many tries in a row failed.
    var backoff: @Sendable (Int) -> Duration = LiveCaptureTiming.standardBackoff

    static let standard = LiveCaptureTiming()

    /// 3, 3, 5, 10, then 15 s while the stream stays away.
    static func standardReconnectDelay(attempt: Int) -> Duration {
        switch attempt {
        case ...2: .seconds(3)
        case 3: .seconds(5)
        case 4: .seconds(10)
        default: .seconds(15)
        }
    }

    /// 1, 2, 4, 8, 16, then 30 s for as long as it takes (the film upload's back-off, without its limit).
    static func standardBackoff(attempt: Int) -> Duration {
        UploadEngine.backoff(attempt: attempt)
    }
}

/// What a live capture needs from the app (the real ones in `LiveCaptureCenter`; tests pass fakes).
struct LiveCaptureDependencies {
    /// The signed-in server; nil while signed out or locked out (the parts wait on this Mac meanwhile).
    var api: () -> (any LiveCaptureAPI)?
    /// Starts ffmpeg.
    var launcher: any LiveProcessLauncher
    /// Every wait: watching the list, back-off, the pause before reconnecting, the grace before a kill.
    var sleeper: Sleeper
    /// Keeps the Mac awake while the capture runs.
    var keepAwake: any LiveKeepAwake
    /// An error that stops every request (401, lockout), with the client that got it: goes to the session's
    /// lockout gate, which asks the coach to sign in again.
    var reportError: (any Error, any LiveCaptureAPI) -> Void
    /// A live status the server answered with (start, finish), for the game page and the games list.
    var statusChanged: (LiveStatus) -> Void
    var timing = LiveCaptureTiming.standard
}

/// Captures one live game on this Mac (docs/LIVE.md "What a capture client does"):
///
/// 1. `start()`: `POST /api/games/{id}/live` without a body; the answer says how long the parts are and
///    which parts the server already has. An already capturing game answers 200: the capture resumes.
/// 2. ffmpeg reads the stream and cuts it into MP4 parts in the game's folder (`LiveFFmpegArguments`). Its
///    list of finished parts is read once a second (`LiveCaptureFolder`).
/// 3. Finished parts are sent strictly in order, one at a time: `POST …/live/segments`, the chunks from the
///    session's `received`, `complete`. A part the server already has is skipped. The local file is deleted
///    only after `complete` answered. Network trouble and server errors (5xx, 429) are retried forever with
///    a capped back-off while the game keeps being recorded ("Waiting for the network: N parts to send"). A
///    part the server itself turns down (422 not a video, 413 too large, an empty file) is kept on this Mac
///    under another name and left out: the next parts are still sent in order. A 401 is never retried: it
///    goes to the lockout gate, and sending waits until the coach has signed in again; ffmpeg keeps
///    recording meanwhile.
/// 4. When ffmpeg exits on its own (the camera or the Wi-Fi dropped) it is started again after a few
///    seconds with the next part number, until the game is ended.
/// 5. `end()` ("End live game"): ffmpeg is interrupted so it closes its last part (killed after 10 s), the
///    remaining parts are sent, then `POST …/live/finish`.
/// 6. A 409 `LIVE_ENDED` from any call: ffmpeg is stopped and the parts not yet sent stay in the folder.
/// 7. Meanwhile the game's live state is read every 10 s (first after 3 s). When the game stops taking film
///    without this Mac having ended it (ended or being finished from another device, no film for too long,
///    the length limit, its job failed or was cancelled), the capture stops as after a `LIVE_ENDED`, at once
///    instead of at the next part. `serverEndReason` and `serverError` say why.
///
/// The stream link is a secret: it reaches ffmpeg's arguments and nothing else. ffmpeg's messages are shown
/// only after `LiveCaptureLog` took the link out, and nothing here writes to the log.
@Observable
final class LiveCaptureController {
    /// What the capture is doing.
    nonisolated enum Phase: Hashable, Sendable {
        /// The server is being asked, or ffmpeg has not received anything yet.
        case starting
        /// ffmpeg is writing parts.
        case capturing
        /// ffmpeg exited on its own; it is started again shortly.
        case reconnecting
        /// "End live game" was pressed: the last parts are being sent.
        case finishing
        case ended(Ending)

        /// Not ended.
        var isActive: Bool {
            if case .ended = self { return false }
            return true
        }
    }

    /// How a capture ended.
    nonisolated enum Ending: Hashable, Sendable {
        /// Ended here: every part is on the server and the server was told.
        case finished
        /// The game no longer takes film (409 `LIVE_ENDED`, or the game is gone).
        case noLongerTakesFilm
        /// Stopped without ending the game: the app is quitting, the coach signed out, or only leftover parts
        /// were sent.
        case stopped
        /// It could not start: the server refused, or ffmpeg would not run (`failure` says which).
        case failed
    }

    /// What the capture does.
    nonisolated enum Mode: Hashable, Sendable {
        /// Read the stream with ffmpeg and send the parts.
        case capture(link: LiveStreamLink, ffmpeg: URL)
        /// Only send the finished parts an earlier run left on this Mac.
        case sendOnly
    }

    let gameID: String
    let mode: Mode
    /// The game's folder on this Mac.
    let folder: LiveCaptureFolder

    private(set) var phase: Phase = .starting
    /// Parts the server has taken from this capture.
    private(set) var partsSent = 0
    /// Finished parts on this Mac that are still to send.
    private(set) var partsWaiting = 0
    /// Parts the server did not accept; they are kept on this Mac and left out.
    private(set) var partsNotAccepted = 0
    /// "Waiting for the network: 3 parts to send", while sending is held up.
    private(set) var waitingNote: String?
    /// The last thing that went wrong (ffmpeg's last message without the link, or a sending problem).
    private(set) var lastProblem: String?
    /// Why the capture could not start (`Ending.failed`).
    private(set) var failure: (any PresentableError)?
    /// Why the game stopped taking film, when the server said (`Ending.noLongerTakesFilm`).
    private(set) var serverEndReason: LiveEndReason?
    /// The game's error when its live analysis failed (`serverEndReason == .failed`): what to show the coach,
    /// e.g. that the server has no GPU set up.
    private(set) var serverError: ErrorInfo?

    /// Finished parts this capture has seen: sent, waiting or not accepted.
    var partsCaptured: Int { partsSent + partsWaiting + partsNotAccepted }
    var isActive: Bool { phase.isActive }

    @ObservationIgnored private let dependencies: LiveCaptureDependencies
    @ObservationIgnored private var segmentSeconds = 120
    /// One past the highest part the server had when the capture started.
    @ObservationIgnored private var serverNextIndex = 0
    /// Finished parts to send, by index.
    @ObservationIgnored private var queue: [LiveCapturePart] = []
    /// Every part index this capture has queued (so a part is never queued twice).
    @ObservationIgnored private var seen: Set<Int> = []
    @ObservationIgnored private var highestIndex = -1
    @ObservationIgnored private var current: (any LiveProcess)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private let uploadWake = PollWakeSignal()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var endRequested = false
    @ObservationIgnored private var serverEnded = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var recordingDone = false
    @ObservationIgnored private var launchFailed = false
    /// The client a 401 or a lockout came from: never used again (a rejected password is not retried).
    @ObservationIgnored private var blockedAPI: (any LiveCaptureAPI)?

    /// A part the server keeps answering oddly about is set aside after this many tries in a row.
    nonisolated static let maximumOddAnswers = 5

    private var timing: LiveCaptureTiming { dependencies.timing }

    init(gameID: String, mode: Mode, folder: LiveCaptureFolder, dependencies: LiveCaptureDependencies) {
        self.gameID = gameID
        self.mode = mode
        self.folder = folder
        self.dependencies = dependencies
    }

    // MARK: - Start

    /// Asks the server to make the game live (or to carry on with it), then starts ffmpeg and the sending in
    /// the background and returns. Throws what the server answered when it refuses; the capture has then
    /// ended (`Ending.failed`, or `.noLongerTakesFilm` after a 409 `LIVE_ENDED`).
    func start() async throws {
        guard !didStart else { return }
        didStart = true
        guard let api = dependencies.api() else {
            end(with: .failed, failure: DisplayError.describing(ServerSessionError.notSignedIn))
            throw ServerSessionError.notSignedIn
        }
        let status: LiveStatus
        do {
            status = try await api.startLive(gameID: gameID)
        } catch {
            if error.stopsAllRequests { dependencies.reportError(error, api) }
            if Self.meansEnded(error) {
                partsWaiting = await Self.snapshot(of: folder, fallbackDuration: Double(segmentSeconds)).pending.count
                end(with: .noLongerTakesFilm, failure: nil)
            } else {
                end(with: .failed, failure: error)
            }
            throw error
        }
        dependencies.statusChanged(status)
        segmentSeconds = max(status.game.live?.segmentSeconds ?? segmentSeconds, 1)
        serverNextIndex = status.nextSegmentIndex
        do {
            try folder.create()
        } catch {
            end(with: .failed, failure: LiveCaptureText.folderUnavailable)
            throw LiveCaptureText.folderUnavailable
        }
        runTask = Task { await self.run() }
    }

    private func end(with ending: Ending, failure: (any PresentableError)?) {
        self.failure = failure
        waitingNote = nil
        phase = .ended(ending)
    }

    // MARK: - End, quit, sign-out

    /// "End live game": ffmpeg is interrupted so it closes its last part, the remaining parts are sent, then
    /// the server is told that no more film is coming. Returns at once; follow `phase`.
    func end() {
        guard phase.isActive, !endRequested, !suspended, !serverEnded else { return }
        endRequested = true
        phase = .finishing
        stopRecording()
    }

    /// Stops the capture without ending the game (the app is quitting, or the coach signed out): ffmpeg is
    /// interrupted and waited for, so its last part is closed and listed; the parts not yet sent and the
    /// game on the server stay as they are, and the capture can be resumed later.
    func suspend() async {
        guard phase.isActive, !suspended else {
            await runTask?.value
            return
        }
        suspended = true
        stopRecording()
        uploadTask?.cancel()
        await runTask?.value
    }

    /// Returns once the capture has ended (at once when it never started).
    func waitUntilEnded() async {
        await runTask?.value
    }

    /// The app is terminating right now: interrupts ffmpeg without waiting. ffmpeg is its own process, so it
    /// still closes its last part; the next launch finds it in the folder.
    func interruptNow() {
        current?.interrupt()
    }

    private func stopRecording() {
        pauseTask?.cancel()
        if let current { stop(current) }
        uploadWake.signal()
    }

    /// Interrupts ffmpeg and kills it if it has not exited after the grace period.
    private func stop(_ process: any LiveProcess) {
        process.interrupt()
        graceTask?.cancel()
        let sleeper = dependencies.sleeper
        let grace = timing.exitGrace
        graceTask = Task {
            do {
                try await sleeper.sleep(for: grace)
            } catch {
                return
            }
            process.terminate()
        }
    }

    private var stopRequested: Bool { endRequested || serverEnded || suspended }

    // MARK: - The capture

    private func run() async {
        dependencies.keepAwake.begin()
        defer { dependencies.keepAwake.end() }
        // Parts an earlier run left here go first.
        await scan()
        let uploader = Task { await self.uploadLoop() }
        uploadTask = uploader
        if case .capture(let link, let ffmpeg) = mode {
            let serverWatch = Task { await self.watchServer() }
            await record(link: link, ffmpeg: ffmpeg)
            serverWatch.cancel()
        }
        await scan()
        recordingDone = true
        uploadWake.signal()
        await uploader.value
        uploadTask = nil
        await conclude()
    }

    /// Runs ffmpeg, again and again while the stream drops, until the capture is told to stop.
    private func record(link: LiveStreamLink, ffmpeg: URL) async {
        var failedRuns = 0
        while !stopRequested {
            // What an earlier run left of a part it never finished goes first: the list is what counts.
            let snapshot = await Self.prepare(folder, fallbackDuration: Double(segmentSeconds))
            adopt(snapshot)
            let startNumber = max(highestIndex + 1, serverNextIndex)
            let arguments = LiveFFmpegArguments.make(
                link: link, segmentSeconds: segmentSeconds, startNumber: startNumber, directory: folder.url, run: snapshot.nextRun)
            let process: any LiveProcess
            do {
                process = try dependencies.launcher.launch(executable: ffmpeg, arguments: arguments, directory: folder.url)
            } catch {
                launchFailed = true
                return
            }
            current = process
            if stopRequested { stop(process) }  // told to stop while it was being started
            let partsBefore = seen.count
            let watcher = Task { await self.watch() }
            _ = await process.waitForExit()
            watcher.cancel()
            await watcher.value
            graceTask?.cancel()
            graceTask = nil
            current = nil
            await scan()
            if stopRequested { return }
            // The camera or the Wi-Fi dropped: say so, wait a little, start again with the next part number.
            lastProblem = LiveCaptureLog.problem(from: process.errorTail(), link: link) ?? LiveCaptureText.streamLost
            failedRuns = seen.count > partsBefore ? 1 : failedRuns + 1
            phase = .reconnecting
            await pause(for: timing.reconnectDelay(failedRuns))
        }
    }

    /// Reads the game's live state every 10 s while the stream is recorded. A game that stopped taking film
    /// without this Mac having asked stops the capture at once.
    private func watchServer() async {
        var interval = timing.firstStatusCheck
        while !Task.isCancelled, !stopRequested {
            guard await wait(interval) else { return }
            interval = timing.statusCheck
            guard !stopRequested, let api = usableAPI() else { continue }
            do {
                let status = try await api.liveStatus(gameID: gameID)
                guard !Task.isCancelled, !stopRequested else { return }
                if status.game.live?.isCapturing == true { continue }
                note(serverEnd: status)
                dependencies.statusChanged(status)
                gameStoppedTakingFilm()
                return
            } catch {
                if Task.isCancelled || error.isCancellation || stopRequested { return }
                if Self.meansEnded(error) {
                    gameStoppedTakingFilm()
                    return
                }
                // Anything else (the network, a sign-in): the sending loop deals with it and shows it.
            }
        }
    }

    /// The game no longer takes film (and it was not this Mac's `finish` that ended it): stop reading the
    /// stream and keep the parts that were not sent.
    private func gameStoppedTakingFilm() {
        guard !serverEnded, !suspended else { return }
        serverEnded = true
        waitingNote = nil
        stopRecording()
        uploadTask?.cancel()
    }

    private func note(serverEnd status: LiveStatus) {
        serverEndReason = status.game.live?.endReason
        serverError = serverEndReason == .failed ? (status.game.error ?? status.job?.error) : nil
    }

    /// Reads ffmpeg's list once a second while it runs.
    private func watch() async {
        while !Task.isCancelled {
            do {
                try await dependencies.sleeper.sleep(for: timing.listPoll)
            } catch {
                return
            }
            let isWriting = await scan()
            if isWriting, phase == .starting || phase == .reconnecting { phase = .capturing }
        }
    }

    /// A wait that `end()` and `suspend()` cut short.
    private func pause(for duration: Duration) async {
        let sleeper = dependencies.sleeper
        let task = Task {
            do {
                try await sleeper.sleep(for: duration)
            } catch {}
        }
        pauseTask = task
        if stopRequested { task.cancel() }
        await task.value
        pauseTask = nil
    }

    /// Looks at the folder and queues the parts that were finished since. Returns whether the stream is
    /// arriving: ffmpeg is writing a part, or it finished one since the last look.
    @discardableResult
    private func scan() async -> Bool {
        let snapshot = await Self.snapshot(of: folder, fallbackDuration: Double(segmentSeconds))
        let foundNewParts = adopt(snapshot)
        return snapshot.isWriting || foundNewParts
    }

    /// Queues the finished parts not seen before. Returns whether there were any.
    @discardableResult
    private func adopt(_ snapshot: LiveCaptureFolder.Snapshot) -> Bool {
        highestIndex = max(highestIndex, snapshot.highestListedIndex ?? -1)
        let new = snapshot.pending.filter { !seen.contains($0.index) }
        guard !new.isEmpty else { return false }
        for part in new { seen.insert(part.index) }
        queue.append(contentsOf: new)
        queue.sort { $0.index < $1.index }
        partsWaiting = queue.count
        uploadWake.signal()
        return true
    }

    /// Before a run of ffmpeg: clears what a run that was cut off left of its last part, then looks.
    @concurrent
    private nonisolated static func prepare(_ folder: LiveCaptureFolder, fallbackDuration: Double) async -> LiveCaptureFolder.Snapshot {
        folder.removeUnfinishedParts()
        return folder.snapshot(fallbackDuration: fallbackDuration)
    }

    @concurrent
    private nonisolated static func snapshot(of folder: LiveCaptureFolder, fallbackDuration: Double) async -> LiveCaptureFolder.Snapshot {
        folder.snapshot(fallbackDuration: fallbackDuration)
    }

    // MARK: - Sending the parts

    /// What became of one try to send a part.
    private nonisolated enum SendOutcome: Sendable {
        /// The server has the part (it took it now, or had it already).
        case sent
        /// The network, the server or something in between failed: try again later, for as long as it takes.
        case networkTrouble(APIError)
        /// The server answered that it wants this part differently (another offset, a new session): ask again.
        case askAgain(APIError)
        /// The server will not take this part.
        case notAccepted(APIError)
        /// The game no longer takes film.
        case gameEnded
        /// A 401 or a lockout: every request stops until the coach signs in again.
        case blocked(APIError)
        /// The part's file is gone or empty.
        case unreadable
        case cancelled
    }

    private func uploadLoop() async {
        var troubles = 0
        var oddAnswers = 0
        while !Task.isCancelled, !serverEnded, !suspended {
            guard let part = queue.first else {
                waitingNote = nil
                if recordingDone { return }
                await uploadWake.wait()
                continue
            }
            guard let api = usableAPI() else {
                waitingNote = LiveCaptureText.waitingForSignIn(queue.count)
                guard await wait(timing.signInCheck) else { return }
                continue
            }
            let outcome = await Self.send(part, file: folder.fileURL(for: part), gameID: gameID, api: api)
            if Task.isCancelled || suspended { return }
            switch outcome {
            case .sent:
                folder.remove(part)
                dropFirst()
                partsSent += 1
                troubles = 0
                oddAnswers = 0
                waitingNote = nil
            case .networkTrouble(let error):
                troubles += 1
                waitingNote = LiveCaptureText.waitingForNetwork(queue.count)
                lastProblem = error.title
                guard await wait(timing.backoff(troubles)) else { return }
            case .askAgain(let error):
                oddAnswers += 1
                if oddAnswers >= Self.maximumOddAnswers {
                    setAside(part, because: error.title)
                    oddAnswers = 0
                } else if oddAnswers > 1 {
                    guard await wait(timing.backoff(oddAnswers - 1)) else { return }
                }
            case .notAccepted(let error):
                setAside(part, because: error.title)
                oddAnswers = 0
            case .unreadable:
                // An empty or unreadable file is never sent; it is kept out of the way like a refused part.
                folder.setAside(part)
                dropFirst()
                partsNotAccepted += 1
                lastProblem = LiveCaptureText.partUnreadable(number: part.index + 1)
                oddAnswers = 0
            case .gameEnded:
                gameStoppedTakingFilm()
                return
            case .blocked(let error):
                block(api, after: error)
                guard await wait(timing.signInCheck) else { return }
            case .cancelled:
                return
            }
        }
    }

    /// The signed-in client, unless it is the one whose password the server rejected.
    private func usableAPI() -> (any LiveCaptureAPI)? {
        guard let api = dependencies.api() else { return nil }
        if let blockedAPI, blockedAPI === api { return nil }
        blockedAPI = nil
        return api
    }

    /// A 401 or a lockout: the session asks the coach to sign in again, and nothing more is sent with this
    /// client (every retry of a rejected password counts toward the server's lockout).
    private func block(_ api: any LiveCaptureAPI, after error: APIError) {
        blockedAPI = api
        dependencies.reportError(error, api)
        waitingNote = LiveCaptureText.waitingForSignIn(queue.count)
    }

    /// Waits; false when the capture was told to stop meanwhile.
    private func wait(_ duration: Duration) async -> Bool {
        do {
            try await dependencies.sleeper.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func dropFirst() {
        if !queue.isEmpty { queue.removeFirst() }
        partsWaiting = queue.count
    }

    /// Keeps a part the server will not take out of the way and goes on with the next one.
    private func setAside(_ part: LiveCapturePart, because reason: String) {
        folder.setAside(part)
        dropFirst()
        partsNotAccepted += 1
        lastProblem = LiveCaptureText.partNotAccepted(number: part.index + 1, reason: reason)
    }

    /// One part: the session, its bytes from where the server stands, `complete`.
    @concurrent
    private nonisolated static func send(
        _ part: LiveCapturePart, file: URL, gameID: String, api: any LiveCaptureAPI
    ) async -> SendOutcome {
        let size = LiveCaptureFolder.fileSize(file)
        guard size > 0, let reader = try? UploadChunkReader(url: file) else { return .unreadable }
        do throws(APIError) {
            var session = try await api.createLivePartUpload(
                gameID: gameID,
                LiveSegmentInit(index: part.index, durationS: part.durationS, size: size, filename: part.fileName))
            if session.status == .complete { return .sent }
            var resumes = 0
            while session.received < session.size {
                let chunkSize = session.chunkSize > 0 ? session.chunkSize : UploadEngine.fallbackChunkSize
                let length = min(chunkSize, session.size - session.received)
                guard let data = try? reader.read(offset: session.received, length: length) else { return .unreadable }
                let answer: UploadSession
                do throws(APIError) {
                    answer = try await api.sendLivePartChunk(uploadID: session.id, offset: session.received, data: data)
                } catch {
                    // 409 with the session: the server stands at another byte. Carry on from its `received`.
                    guard let resume = error.upload, resume.id == session.id, resume.status == .open,
                          resume.received != session.received, resume.received <= session.size, resumes < 3
                    else { throw error }
                    resumes += 1
                    session = resume
                    continue
                }
                guard answer.received > session.received else {
                    return .askAgain(.decoding(status: 200, detail: "received"))
                }
                session = answer
            }
            _ = try await api.completeLivePartUpload(id: session.id)
            return .sent
        } catch {
            return outcome(for: error)
        }
    }

    /// The game no longer takes film: 409 `LIVE_ENDED`, or the game (or its live stream) is gone.
    nonisolated static func meansEnded(_ error: APIError) -> Bool {
        error.code == ErrorCode.liveEnded || error.code == ErrorCode.notFound
    }

    /// Sorts a failed request (docs/LIVE.md "What a capture client does", steps 3 and 6).
    private nonisolated static func outcome(for error: APIError) -> SendOutcome {
        if error.isCancellation { return .cancelled }
        if error.stopsAllRequests { return .blocked(error) }
        guard case .server(let info, let status, let upload) = error else {
            // No answer from the Scout server itself: offline, a timeout, a sign-in page of the gym's Wi-Fi,
            // a proxy's error page. The part waits.
            if case .local = error { return .unreadable }
            return .networkTrouble(error)
        }
        if meansEnded(error) { return .gameEnded }
        // Worth waiting for: the server says so, it is failing (5xx), or it asks to slow down (429, 408).
        if info.retryable || status >= 500 || status == 429 || status == 408 { return .networkTrouble(error) }
        // A chunk the server wants from another byte, or a session it no longer has: the next try asks again.
        if upload != nil || info.code == ErrorCode.uploadNotFound || info.code == ErrorCode.uploadIncomplete {
            return .askAgain(error)
        }
        return .notAccepted(error)
    }

    // MARK: - The end

    private func conclude() async {
        partsWaiting = queue.count
        waitingNote = nil
        if serverEnded {
            // A refused part does not say why the game ended: ask once, so the panel can.
            if serverEndReason == nil, let api = usableAPI(), let status = try? await api.liveStatus(gameID: gameID) {
                note(serverEnd: status)
                dependencies.statusChanged(status)
            }
            phase = .ended(.noLongerTakesFilm)
        } else if suspended {
            phase = .ended(.stopped)
        } else if endRequested {
            let told = await tellServerTheGameIsOver()
            waitingNote = nil
            if suspended {
                phase = .ended(.stopped)
            } else if told {
                folder.removeIfNoFilmIsLeft(fallbackDuration: Double(segmentSeconds))
                phase = .ended(.finished)
            } else {
                phase = .ended(.stopped)
            }
        } else if launchFailed {
            failure = LiveCaptureText.ffmpegWouldNotStart
            phase = .ended(.failed)
        } else {
            phase = .ended(.stopped)
        }
    }

    /// `POST …/live/finish`, tried for as long as the network takes. False when the server would not take it
    /// (the banner's End button can still ask it directly) or the capture was stopped meanwhile.
    private func tellServerTheGameIsOver() async -> Bool {
        var troubles = 0
        while !suspended {
            guard let api = usableAPI() else {
                waitingNote = LiveCaptureText.waitingForSignIn(queue.count)
                guard await wait(timing.signInCheck) else { return false }
                continue
            }
            do {
                let status = try await api.finishLive(gameID: gameID)
                dependencies.statusChanged(status)
                return true
            } catch {
                if error.isCancellation { return false }
                if Self.meansEnded(error) { return true }  // it is over already
                switch Self.outcome(for: error) {
                case .blocked:
                    block(api, after: error)
                    guard await wait(timing.signInCheck) else { return false }
                case .networkTrouble:
                    troubles += 1
                    waitingNote = LiveCaptureText.waitingToEnd
                    lastProblem = error.title
                    guard await wait(timing.backoff(troubles)) else { return false }
                default:
                    lastProblem = error.title
                    return false
                }
            }
        }
        return false
    }
}
#endif
