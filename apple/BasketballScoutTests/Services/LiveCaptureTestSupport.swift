#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// The waits of a capture under test, each of its own length so the sleeper can tell them apart.
nonisolated enum LiveTestTiming {
    static let listPoll: Duration = .milliseconds(100)
    static let exitGrace: Duration = .seconds(10)
    static let signInCheck: Duration = .seconds(5)
    static let firstStatusCheck: Duration = .seconds(7)
    static let statusCheck: Duration = .seconds(9)

    /// 61, 62, 63 … s: the pause before run `attempt + 1` of ffmpeg.
    static func reconnect(_ attempt: Int) -> Duration { .seconds(60 + attempt) }

    static let timing = LiveCaptureTiming(
        listPoll: listPoll, exitGrace: exitGrace, signInCheck: signInCheck, firstStatusCheck: firstStatusCheck,
        statusCheck: statusCheck, reconnectDelay: { reconnect($0) }, backoff: LiveCaptureTiming.standardBackoff)
}

/// A sleeper for capture tests: the list poll really waits a millisecond (and is not recorded), waits in
/// `held` stay asleep until the test releases them (or their task is cancelled), every other wait is
/// recorded and returns at once.
nonisolated final class LiveTestSleeper: Sendable {
    private struct State {
        var recorded: [Duration] = []
        var held: Set<Duration>
        var waiters: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state: Mutex<State>

    /// By default the grace before a kill and the server-state checks never fire on their own.
    init(holding held: Set<Duration> = [LiveTestTiming.exitGrace, LiveTestTiming.firstStatusCheck, LiveTestTiming.statusCheck]) {
        state = Mutex(State(held: held))
    }

    /// Every wait that started except the list polls, in order.
    var recorded: [Duration] { state.withLock { $0.recorded } }

    /// How many tasks are asleep in a held wait of `duration`.
    func waitingCount(_ duration: Duration) -> Int {
        state.withLock { state in state.waiters.values.filter { $0.duration == duration }.count }
    }

    func hold(_ duration: Duration) {
        state.withLock { _ = $0.held.insert(duration) }
    }

    /// Wakes the tasks asleep in a held wait of `duration`; later waits of that length return at once unless
    /// `keepHolding`.
    func release(_ duration: Duration, keepHolding: Bool = false) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            if !keepHolding { state.held.remove(duration) }
            let ids = state.waiters.filter { $0.value.duration == duration }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in woken { continuation.resume() }
    }

    var sleeper: Sleeper {
        Sleeper { [self] duration in
            try Task.checkCancellation()
            if duration == LiveTestTiming.listPoll {
                try await Task.sleep(for: .milliseconds(1))
                return
            }
            let isHeld = state.withLock { state -> Bool in
                state.recorded.append(duration)
                return state.held.contains(duration)
            }
            guard isHeld else {
                // A capture that waits for a sign-in looks again and again: give it a real moment.
                if duration == LiveTestTiming.signInCheck { try await Task.sleep(for: .milliseconds(1)) }
                await Task.yield()
                try Task.checkCancellation()
                return
            }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let alreadyCancelled = state.withLock { state -> Bool in
                        if state.cancelled.remove(id) != nil { return true }
                        state.waiters[id] = (duration, continuation)
                        return false
                    }
                    if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                    if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
                    state.cancelled.insert(id)
                    return nil
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
}

/// A scripted Scout server for the capture: it keeps the parts it was sent, answers like the real routes
/// (docs/LIVE.md "HTTP API") and can be told to fail a call.
nonisolated final class FakeLiveAPI: LiveCaptureAPI {
    enum Call: Hashable, Sendable, CustomStringConvertible {
        case start
        case status
        case create(index: Int)
        case chunk(index: Int, offset: Int, count: Int)
        case complete(index: Int)
        case finish

        var description: String {
            switch self {
            case .start: "start"
            case .status: "status"
            case .create(let index): "create(\(index))"
            case .chunk(let index, let offset, let count): "chunk(\(index), \(offset), \(count))"
            case .complete(let index): "complete(\(index))"
            case .finish: "finish"
            }
        }
    }

    /// The kinds of call a failure can be queued for.
    enum Step: Hashable, Sendable { case start, status, create, chunk, complete, finish }

    private struct Upload {
        var id: String
        var index: Int
        var size: Int
        var duration: Double
        var data = Data()
        var isComplete = false
    }

    private struct State {
        var calls: [Call] = []
        var failures: [Step: [APIError]] = [:]
        var uploads: [String: Upload] = [:]
        var parts: [Int: Data] = [:]
        var durations: [Int: Double] = [:]
        var existing: Set<Int> = []
        var halfSent: [Int: Data] = [:]
        var segmentSeconds = 120
        var chunkSize = 1000
        var liveState = LiveState.capturing
        var endReason: LiveEndReason?
        var gameError: ErrorInfo?
        var counter = 0
    }

    let gameID: String
    private let state = Mutex(State())

    init(gameID: String = "g_live00000001") {
        self.gameID = gameID
    }

    // MARK: Script

    var calls: [Call] { state.withLock { $0.calls } }
    /// The parts the server took, by index.
    var parts: [Int: Data] { state.withLock { $0.parts } }
    var durations: [Int: Double] { state.withLock { $0.durations } }
    var liveState: LiveState { state.withLock { $0.liveState } }

    func count(_ step: Step) -> Int {
        calls.filter { Self.step(of: $0) == step }.count
    }

    /// The next calls of `step` fail with `errors`, one each.
    func fail(_ step: Step, with errors: APIError...) {
        state.withLock { $0.failures[step, default: []].append(contentsOf: errors) }
    }

    func set(segmentSeconds: Int? = nil, chunkSize: Int? = nil) {
        state.withLock { state in
            if let segmentSeconds { state.segmentSeconds = segmentSeconds }
            if let chunkSize { state.chunkSize = chunkSize }
        }
    }

    /// The server already has these parts (sent before the app was quit).
    func alreadyHas(_ indexes: Int...) {
        state.withLock { $0.existing.formUnion(indexes) }
    }

    /// The server has the first bytes of a part (an upload that was cut off).
    func hasFirstBytes(of index: Int, _ data: Data) {
        state.withLock { $0.halfSent[index] = data }
    }

    /// The game stops taking film (ended elsewhere, idle, its job failed …).
    func stopTakingFilm(_ liveState: LiveState = .ended, reason: LiveEndReason? = .finished, error: ErrorInfo? = nil) {
        state.withLock { state in
            state.liveState = liveState
            state.endReason = reason
            state.gameError = error
        }
    }

    static func step(of call: Call) -> Step {
        switch call {
        case .start: .start
        case .status: .status
        case .create: .create
        case .chunk: .chunk
        case .complete: .complete
        case .finish: .finish
        }
    }

    static func serverError(_ status: Int, code: String, title: String, retryable: Bool = false, upload: UploadSession? = nil) -> APIError {
        .server(ErrorInfo(code: code, title: title, message: title, retryable: retryable), status: status, upload: upload)
    }

    static let liveEnded = serverError(409, code: ErrorCode.liveEnded, title: "The live game has ended")
    static let offline = APIError.transport(URLError(.notConnectedToInternet))

    // MARK: LiveCaptureAPI

    func startLive(gameID: String) async throws(APIError) -> LiveStatus {
        try record(.start)
        return try state.withLock { state throws(APIError) -> LiveStatus in
            guard state.liveState == .capturing else { throw Self.liveEnded }
            return Self.status(&state, gameID: gameID)
        }
    }

    func liveStatus(gameID: String) async throws(APIError) -> LiveStatus {
        try record(.status)
        return state.withLock { Self.status(&$0, gameID: gameID) }
    }

    func createLivePartUpload(gameID: String, _ body: LiveSegmentInit) async throws(APIError) -> UploadSession {
        try record(.create(index: body.index))
        return try state.withLock { state throws(APIError) -> UploadSession in
            guard state.liveState == .capturing else { throw Self.liveEnded }
            if state.existing.contains(body.index) || state.parts[body.index] != nil {
                return Self.session(Upload(id: "u_done_\(body.index)", index: body.index, size: body.size, duration: body.durationS, data: Data(count: body.size), isComplete: true), state)
            }
            if let open = state.uploads.values.first(where: { $0.index == body.index && !$0.isComplete && $0.size == body.size }) {
                return Self.session(open, state)
            }
            state.counter += 1
            var upload = Upload(id: "u_\(body.index)_\(state.counter)", index: body.index, size: body.size, duration: body.durationS)
            if let prefix = state.halfSent.removeValue(forKey: body.index) { upload.data = prefix }
            state.uploads[upload.id] = upload
            return Self.session(upload, state)
        }
    }

    func sendLivePartChunk(uploadID: String, offset: Int, data: Data) async throws(APIError) -> UploadSession {
        let index = state.withLock { $0.uploads[uploadID]?.index ?? -1 }
        try record(.chunk(index: index, offset: offset, count: data.count))
        return try state.withLock { state throws(APIError) -> UploadSession in
            guard var upload = state.uploads[uploadID] else {
                throw Self.serverError(404, code: ErrorCode.uploadNotFound, title: "Upload not found")
            }
            guard offset == upload.data.count else {
                throw Self.serverError(409, code: ErrorCode.conflict, title: "Conflict", upload: Self.session(upload, state))
            }
            upload.data.append(data)
            state.uploads[uploadID] = upload
            return Self.session(upload, state)
        }
    }

    func completeLivePartUpload(id: String) async throws(APIError) -> FilmResult {
        let index = state.withLock { $0.uploads[id]?.index ?? -1 }
        try record(.complete(index: index))
        let game = gameID
        return try state.withLock { state throws(APIError) -> FilmResult in
            guard state.liveState == .capturing else { throw Self.liveEnded }
            guard var upload = state.uploads[id] else {
                throw Self.serverError(404, code: ErrorCode.uploadNotFound, title: "Upload not found")
            }
            guard upload.data.count == upload.size else {
                throw Self.serverError(409, code: ErrorCode.uploadIncomplete, title: "Upload incomplete")
            }
            upload.isComplete = true
            state.uploads[id] = upload
            state.parts[upload.index] = upload.data
            state.durations[upload.index] = upload.duration
            return FilmResult(game: Self.game(state, gameID: game), job: nil)
        }
    }

    func finishLive(gameID: String) async throws(APIError) -> LiveStatus {
        try record(.finish)
        return state.withLock { state in
            if state.liveState == .capturing {
                state.liveState = .finishing
                state.endReason = .finished
            }
            return Self.status(&state, gameID: gameID)
        }
    }

    // MARK: Helpers

    /// Notes the call, then fails it when a failure is queued for its kind.
    private func record(_ call: Call) throws(APIError) {
        let failure = state.withLock { state -> APIError? in
            state.calls.append(call)
            let step = Self.step(of: call)
            guard var queue = state.failures[step], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            state.failures[step] = queue
            return next
        }
        if let failure { throw failure }
    }

    private static func session(_ upload: Upload, _ state: State) -> UploadSession {
        UploadSession(
            id: upload.id, gameID: "g", filename: LiveFFmpegArguments.partFileName(index: upload.index), size: upload.size,
            received: upload.data.count, chunkSize: state.chunkSize, status: upload.isComplete ? .complete : .open,
            liveSegment: upload.index, liveDurationS: upload.duration, createdAt: nil, updatedAt: nil)
    }

    private static func game(_ state: State, gameID: String) -> Game {
        let indexes = Set(state.parts.keys).union(state.existing)
        return Game(
            id: gameID, scoutedTeam: "Test Team A", otherTeam: "Test Team B", status: indexes.isEmpty ? .processing : .ready,
            live: LiveInfo(
                state: state.liveState, segmentSeconds: state.segmentSeconds, segmentsReceived: indexes.count,
                endReason: state.endReason),
            error: state.gameError)
    }

    private static func status(_ state: inout State, gameID: String) -> LiveStatus {
        let indexes = Set(state.parts.keys).union(state.existing).sorted()
        let segments = indexes.map { index in
            LiveSegment(
                gameID: gameID, index: index, durationS: state.durations[index] ?? Double(state.segmentSeconds),
                size: state.parts[index]?.count ?? 1, filename: LiveFFmpegArguments.partFileName(index: index),
                status: .uploaded, attempts: 0, processor: nil, externalID: nil, progress: nil, error: nil,
                uploadedAt: nil, submittedAt: nil, finishedAt: nil)
        }
        return LiveStatus(game: game(state, gameID: gameID), segments: segments, job: nil)
    }
}

/// A stand-in for a running ffmpeg: the test writes its parts and its list, and decides when it exits.
nonisolated final class FakeLiveProcess: LiveProcess {
    private struct State {
        var exitStatus: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var interrupts = 0
        var terminations = 0
        var tail: [String] = []
        var onInterrupt: (@Sendable (FakeLiveProcess) -> Void)?
    }

    let arguments: [String]
    let directory: URL
    private let state = Mutex(State())

    init(arguments: [String], directory: URL) {
        self.arguments = arguments
        self.directory = directory
    }

    // MARK: What ffmpeg was asked to do

    func value(after option: String) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    var startNumber: Int { value(after: "-segment_start_number").flatMap(Int.init) ?? -1 }
    var segmentSeconds: Int { value(after: "-segment_time").flatMap(Int.init) ?? -1 }
    var listFile: URL { URL(fileURLWithPath: value(after: "-segment_list") ?? "/nowhere") }
    var inputLink: String? { value(after: "-i") }

    // MARK: Acting like ffmpeg

    /// Deterministic bytes of part `index` (an MP4 header, then a pattern), `count` long.
    static func bytes(index: Int, count: Int) -> Data {
        let header = Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8)
        guard count > header.count else { return Data(header.prefix(count)) }
        return header + Data((0..<(count - header.count)).map { UInt8(truncatingIfNeeded: ($0 &* 7 &+ index &* 31) % 251) })
    }

    /// Starts writing part `index` (a file with bytes that no list names yet).
    func beginPart(_ index: Int) throws {
        try Data(Self.bytes(index: index, count: 64)).write(to: partFile(index))
    }

    /// Finishes part `index`: the whole file, then its line in the list (file, start, end).
    @discardableResult
    func finishPart(_ index: Int, bytes count: Int = 2500, start: Double? = nil, length: Double = 120.133333) throws -> Data {
        let data = Self.bytes(index: index, count: count)
        try data.write(to: partFile(index))
        let begin = start ?? Double(index) * 120
        try appendToList(String(format: "%@,%.6f,%.6f\n", LiveFFmpegArguments.partFileName(index: index), begin, begin + length))
        return data
    }

    func appendToList(_ text: String) throws {
        let file = listFile
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try Data().write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func partFile(_ index: Int) -> URL {
        directory.appending(path: LiveFFmpegArguments.partFileName(index: index), directoryHint: .notDirectory)
    }

    /// What it does when it is interrupted (default: it exits, as ffmpeg does; `{ _ in }` for one that hangs).
    func onInterrupt(_ body: @escaping @Sendable (FakeLiveProcess) -> Void) {
        state.withLock { $0.onInterrupt = body }
    }

    func say(_ lines: String...) {
        state.withLock { $0.tail.append(contentsOf: lines) }
    }

    /// The process ends.
    func exit(_ status: Int32 = 0) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
            guard state.exitStatus == nil else { return [] }
            state.exitStatus = status
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    var interrupts: Int { state.withLock { $0.interrupts } }
    var terminations: Int { state.withLock { $0.terminations } }
    var hasExited: Bool { state.withLock { $0.exitStatus != nil } }

    // MARK: LiveProcess

    func interrupt() {
        let body = state.withLock { state -> (@Sendable (FakeLiveProcess) -> Void)? in
            state.interrupts += 1
            return state.onInterrupt
        }
        if let body {
            body(self)
        } else {
            exit(255)
        }
    }

    func terminate() {
        state.withLock { $0.terminations += 1 }
        exit(15)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
    }

    func errorTail() -> [String] {
        state.withLock { $0.tail }
    }
}

/// Starts `FakeLiveProcess`es and keeps them for the test.
nonisolated final class FakeLiveLauncher: LiveProcessLauncher {
    struct CannotLaunch: Error {}

    private struct State {
        var processes: [FakeLiveProcess] = []
        var executables: [URL] = []
        var failsToLaunch = false
    }

    private let state = Mutex(State())

    var processes: [FakeLiveProcess] { state.withLock { $0.processes } }
    var executables: [URL] { state.withLock { $0.executables } }

    func failToLaunch(_ fails: Bool = true) {
        state.withLock { $0.failsToLaunch = fails }
    }

    func launch(executable: URL, arguments: [String], directory: URL) throws -> any LiveProcess {
        try state.withLock { state in
            if state.failsToLaunch { throw CannotLaunch() }
            let process = FakeLiveProcess(arguments: arguments, directory: directory)
            state.processes.append(process)
            state.executables.append(executable)
            return process
        }
    }
}

/// Counts what the capture asked of the Mac.
@MainActor
final class FakeKeepAwake: LiveKeepAwake {
    private(set) var begins = 0
    private(set) var ends = 0
    var isAwake: Bool { begins > ends }

    func begin() { begins += 1 }
    func end() { ends += 1 }
}

/// One capture with fakes around it, in a folder of its own.
@MainActor
final class LiveCaptureHarness {
    static let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    /// A link with a stream key, as a camera's might be.
    static let linkText = "rtmp://192.168.1.50/live/secretkey123"

    let gameID = "g_live00000001"
    let api: FakeLiveAPI
    let launcher = FakeLiveLauncher()
    let sleeper: LiveTestSleeper
    let keepAwake = FakeKeepAwake()
    let root: ServiceTestFolder
    let folder: LiveCaptureFolder
    /// The client the capture gets (nil: signed out).
    var currentAPI: (any LiveCaptureAPI)?
    private(set) var reported: [APIError] = []
    private(set) var statuses: [LiveStatus] = []

    init(sleeper: LiveTestSleeper = LiveTestSleeper()) throws {
        self.sleeper = sleeper
        api = FakeLiveAPI(gameID: gameID)
        currentAPI = api
        root = try ServiceTestFolder("LiveCapture")
        folder = LiveCaptureFolder(gameID: gameID, root: root.url)
    }

    var link: LiveStreamLink {
        get throws { try LiveStreamLink(userInput: Self.linkText) }
    }

    var dependencies: LiveCaptureDependencies {
        LiveCaptureDependencies(
            api: { [unowned self] in currentAPI },
            launcher: launcher,
            sleeper: sleeper.sleeper,
            keepAwake: keepAwake,
            reportError: { [unowned self] error, _ in
                if let error = error as? APIError { reported.append(error) }
            },
            statusChanged: { [unowned self] status in statuses.append(status) },
            timing: LiveTestTiming.timing)
    }

    func capture(_ mode: LiveCaptureController.Mode? = nil) throws -> LiveCaptureController {
        LiveCaptureController(
            gameID: gameID, mode: try mode ?? .capture(link: link, ffmpeg: Self.ffmpeg), folder: folder, dependencies: dependencies)
    }

    /// The `index`-th ffmpeg the capture started, once it has.
    func process(_ index: Int = 0) async throws -> FakeLiveProcess {
        try await waitUntil("ffmpeg run \(index + 1)") { launcher.processes.count > index }
        return launcher.processes[index]
    }

    /// Names of the files in the game's folder.
    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path(percentEncoded: false))) ?? []).sorted()
    }

    func cleanUp() {
        root.remove()
    }
}
#endif
