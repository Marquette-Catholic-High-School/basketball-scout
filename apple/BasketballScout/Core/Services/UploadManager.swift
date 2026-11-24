import Foundation
import Observation
import os

/// Film uploads, at most one per game: chunked, resumable and persisted (04 §2, §6.1; 09 D1 #8,
/// R15–R20). The protocol itself runs in `UploadEngine`, off the main actor.
///
/// Wiring (AppModel): set `clientProvider` (the signed-in client, nil when signed out),
/// `maxUploadBytesProvider` (`health.max_upload_bytes`) and `errorReporter` (→ `ServerSession.report`).
/// Call `resumePendingUploads()` once the signed-in gate has passed (launch, sign-in) and
/// `suspendAll()` from the lockout gate and on sign-out (09 R6). Listen to `events` to open the game
/// when its upload finishes.
///
/// Behaviour (the web's upload page, upload.js):
/// - `start` checks the file (extension, empty, size limit), resumes the stored session of the same
///   file (name, size, modification date and a fingerprint, 09 R17) or creates one, and runs. A file
///   chosen while another one uploads for that game is ignored.
/// - Pause aborts the chunk in flight (the server drops its bytes); Resume first asks the server what
///   it has. Cancel deletes the session (also one that arrives after the cancel). Neither works while
///   `complete` runs: it is a commit point (04 §2.6, §8.9).
/// - A session the server aborted or lost (another film or link won, 09 R20) ends with "Upload this
///   file again"; a refused film with "Choose another file" only.
/// - In-progress uploads are saved (`UploadStore`) and continue after a relaunch, a sign-in or a
///   return to the foreground. iOS: the screen stays awake while uploading and the background grace
///   period is used to finish or stop cleanly (`SystemUploadActivity`).
@Observable
final class UploadManager {
    /// Each game's upload, keyed by game id. Finished, failed and cancelled ones stay until
    /// `dismiss(gameID:)` or the next `start` for the game.
    private(set) var uploads: [String: UploadState] = [:]

    /// The most recent event (`events` delivers every one).
    private(set) var lastEvent: UploadEvent?

    /// The signed-in server's client; nil while signed out (nothing is sent then).
    @ObservationIgnored var clientProvider: () -> APIClient? = { nil }
    /// The server's `max_upload_bytes` (`/api/health`) for the size check before any request (04 §6.1).
    @ObservationIgnored var maxUploadBytesProvider: () -> Int? = { nil }
    /// Gets each `APIError` an upload stops with, before it is shown: pass it to
    /// `ServerSession.report(_:)` so 401/429 reach the lockout gate (09 R6). Not called for
    /// `submitVideoLink`, which throws to its caller.
    @ObservationIgnored var errorReporter: (any Error) -> Void = { _ in }

    /// Where pending uploads and the app's film copies are kept.
    nonisolated let store: UploadStore

    @ObservationIgnored private let activity: any UploadActivityMonitor
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let progressInterval: Duration?
    @ObservationIgnored private let clockStart = ContinuousClock.now
    @ObservationIgnored private var runs: [String: UploadRun] = [:]
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<UploadEvent>.Continuation] = [:]
    /// Set by `suspendAll()` (lockout, sign-out) until `resumePendingUploads()`.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var didRestoreRecords = false
    @ObservationIgnored private var tickerTask: Task<Void, Never>?
    @ObservationIgnored private var orphanTask: Task<Void, Never>?

    /// - Parameters:
    ///   - store: pending uploads and copies (default `Application Support/Uploads`).
    ///   - activity: app life cycle (default `SystemUploadActivity`).
    ///   - sleeper: the retry back-off's clock.
    ///   - progressInterval: how often bytes in flight and the speed are refreshed (nil: only when a
    ///     chunk completes).
    init(
        store: UploadStore? = nil,
        activity: (any UploadActivityMonitor)? = nil,
        sleeper: Sleeper = .live,
        progressInterval: Duration? = .milliseconds(250)
    ) {
        self.store = store ?? .standard()
        self.activity = activity ?? SystemUploadActivity()
        self.sleeper = sleeper
        self.progressInterval = progressInterval
        self.activity.onBackgroundTimeExpiring = { [weak self] in self?.pauseForBackground() }
        self.activity.onBecameActive = { [weak self] in self?.resumeAfterBackground() }
    }

    // MARK: - Reading

    /// The upload of `gameID`, if any.
    func upload(for gameID: String) -> UploadState? {
        uploads[gameID]
    }

    /// Some upload is preparing, sending or completing.
    var hasActiveUploads: Bool {
        uploads.values.contains { $0.isActive }
    }

    /// Every event from now on (finished, failed, cancelled); each access is a new subscription.
    var events: AsyncStream<UploadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: UploadEvent.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: - Starting

    /// Uploads `film` as the film of `gameID` (replacing its current film once complete). Returns when
    /// the upload is running (or refused); follow `uploads[gameID]` and `events`.
    func start(gameID: String, film: FilmSource) async {
        if let current = runs[gameID], current.isBusy, current.stopReason != .cancel {
            // upload.js:182: a file chosen while one uploads is ignored. A copy handed over is the manager's to
            // delete (`FilmSource.copied`), so it goes now instead of waiting for the next launch's clean-up.
            discardIgnoredCopy(film, keeping: current)
            return
        }
        let fileName = film.fileName
        guard let client = clientProvider() else {
            let run = UploadRun(gameID: gameID)
            replaceRun(with: run)
            fail(run, fileName: fileName, error: UploadError.notSignedIn, canUploadAgain: false)
            return
        }
        let run = UploadRun(gameID: gameID)
        replaceRun(with: run)
        run.isPreparing = true
        uploads[gameID] = UploadState(gameID: gameID, fileName: fileName, phase: .preparing, statusText: "Starting upload…")
        updateActivity()

        let opened: Result<PreparedFilm, UploadError>
        do {
            opened = .success(try await PreparedFilm.open(film, store: store))
        } catch {
            opened = .failure(error)
        }
        run.isPreparing = false
        guard runs[gameID] === run, run.stopReason != .cancel else {
            // Cancelled or replaced while the file was being opened.
            if case .success(let prepared) = opened { prepared.discard(in: store) }
            if runs[gameID] === run { runs[gameID] = nil }
            updateActivity()
            return
        }
        let prepared: PreparedFilm
        switch opened {
        case .success(let value):
            prepared = value
        case .failure(let error):
            fail(run, fileName: fileName, error: error, canUploadAgain: false)
            return
        }
        run.file = prepared.file
        run.access = prepared.access

        // Client-side checks before any request (upload.js:136-152).
        if let problem = validate(prepared.file) {
            prepared.discard(in: store)
            run.file = nil
            run.access = nil
            fail(run, fileName: prepared.file.name, error: problem, canUploadAgain: false)
            return
        }

        // The earlier upload of this game: continue it when it is the same file (04 §2.8), else drop it.
        let origin = client.address.originString
        var candidate: String?
        if let earlier = store.record(for: gameID) {
            let sameFile = earlier.serverOrigin == origin && earlier.identity.matches(
                prepared.identity, checkingModificationDate: !(earlier.isCopy || prepared.isCopy))
            if sameFile {
                candidate = earlier.uploadID
            } else if let uploadID = earlier.uploadID, earlier.serverOrigin == origin {
                deleteSession(uploadID)
            }
            if case .copied(let path) = earlier.source, path != prepared.copyPath { store.removeCopy(path) }
        }
        let record = UploadRecord(
            gameID: gameID, serverOrigin: origin, uploadID: candidate, identity: prepared.identity,
            source: prepared.source, wantsToRun: true)
        run.record = record
        store.save(record)
        update(gameID) { state in
            state.fileName = prepared.file.name
            state.totalBytes = prepared.file.size
            state.uploadID = candidate
        }
        switch run.stopReason {
        case .pause?, .suspend?, .background?:
            stopped(run, reason: run.stopReason)  // paused while the file was being opened
            resumeIfAsked(run)
        case .cancel?, .discard?:
            break
        case nil:
            launch(run, mode: .start(candidate: candidate), client: client)
        }
    }

    // MARK: - Controls

    /// Stops the upload; the part already sent stays on the server. Not while `complete` runs.
    func pause(gameID: String) {
        guard let run = runs[gameID], run.isBusy, !run.isCompleting else { return }
        run.stopReason = .pause
        run.resumeWhenStopped = false
        run.task?.cancel()
        setRecord(run) { $0.wantsToRun = false }
        setPaused(run, reason: .user)
    }

    /// Continues a paused upload (or one that failed with its session kept): asks the server what it
    /// has, then goes on from there (upload.js:338-363). Right after Pause the stopped run may still be
    /// winding down (its chunk being cancelled): the upload then shows "Checking…" at once and continues as
    /// soon as the run has stopped, so the button never does nothing.
    func resume(gameID: String) {
        guard let run = runs[gameID], let state = uploads[gameID], state.canResume else { return }
        if run.isBusy {
            guard run.stopReason == .pause else { return }
            run.resumeWhenStopped = true
            update(gameID) { state in
                state.phase = .preparing
                state.pauseReason = nil
                state.statusText = UploadEngine.Activity.checking.statusText
                state.hasServerSession = false
                state.canUploadAgain = false
            }
            return
        }
        guard let client = clientProvider() else { return }
        guard let uploadID = run.record?.uploadID else {
            restart(gameID: gameID)
            return
        }
        resumeRun(run, mode: .resume(uploadID: uploadID), client: client)
    }

    /// "Upload this file again": a new session for the same file, from byte 0 (after the server lost or
    /// aborted the old one).
    func restart(gameID: String) {
        guard let run = runs[gameID], !run.isBusy, let record = run.record else { return }
        guard let client = clientProvider() else { return }
        if let uploadID = record.uploadID { deleteSession(uploadID) }
        setRecord(run) { record in
            record.uploadID = nil
            record.lastReceived = 0
            record.serverOrigin = client.address.originString
        }
        store.save(run.record ?? record)
        resumeRun(run, mode: .start(candidate: nil), client: client)
    }

    /// Cancels the upload and deletes its session on the server (errors ignored), including a session
    /// that is still being created (upload.js:199, 365-385). Ask first: "Cancel this upload? The part
    /// already sent will be discarded." Not while `complete` runs.
    func cancel(gameID: String) {
        guard let run = runs[gameID], !run.isCompleting, let state = uploads[gameID], state.canCancel else { return }
        run.stopReason = .cancel
        run.resumeWhenStopped = false
        let isRunning = run.task != nil
        run.task?.cancel()
        if run.record == nil, run.isPreparing, let earlier = store.record(for: gameID) {
            // Cancelled while a new file was being opened: the earlier upload it replaces goes too.
            if let uploadID = earlier.uploadID { deleteSession(uploadID) }
            if case .copied(let path) = earlier.source { store.removeCopy(path) }
        }
        if run.record != nil || run.isPreparing { store.removeRecord(for: gameID) }
        uploads[gameID] = UploadState(
            gameID: gameID, fileName: state.fileName, phase: .cancelled, statusText: "",
            bytesSent: state.bytesSent, totalBytes: state.totalBytes)
        if !isRunning {
            if let uploadID = run.record?.uploadID { deleteSession(uploadID) }
            if !run.isPreparing {
                discardFiles(of: run)
                runs[gameID] = nil
            }
        }
        // A running task ends in `ended`, which deletes the session it had (or just got) and the copy; a
        // file still being opened is dropped once it is open.
        updateActivity()
        emit(.cancelled(gameID: gameID))
    }

    /// Forgets a finished, failed, cancelled or paused upload of `gameID` and its copied file; the
    /// server session of a paused or failed one is deleted (it is abandoned).
    func dismiss(gameID: String) {
        if let run = runs[gameID] {
            guard !run.isBusy else { return }
            if let uploadID = run.record?.uploadID, uploads[gameID]?.phase != .finished { deleteSession(uploadID) }
            // A run without a record (a file refused before any request) leaves an earlier one alone.
            if run.record != nil { store.removeRecord(for: gameID) }
            discardFiles(of: run)
            runs[gameID] = nil
        }
        uploads[gameID] = nil
    }

    /// The lockout gate (09 R6) and sign-out: stops every running upload at once (a `complete` already
    /// sent may finish); they continue after `resumePendingUploads()`.
    func suspendAll() {
        isSuspended = true
        for run in runs.values where run.isBusy && !run.isCompleting {
            run.stopReason = .suspend
            run.resumeWhenStopped = false
            run.task?.cancel()
            setPaused(run, reason: .signedOut)
        }
    }

    /// After launch or sign-in, once the signed-in gate has passed: shows the saved uploads of this
    /// server and continues those that were running (not those the coach paused), and deletes sessions
    /// that were abandoned while the server could not be told.
    func resumePendingUploads() {
        isSuspended = false
        guard let client = clientProvider() else { return }
        let origin = client.address.originString
        if !didRestoreRecords {
            didRestoreRecords = true
            store.removeUnreferencedCopies()
        }
        for record in store.records where record.serverOrigin == origin && runs[record.gameID] == nil {
            let run = UploadRun(gameID: record.gameID, record: record)
            runs[record.gameID] = run
            uploads[record.gameID] = UploadState(
                gameID: record.gameID, fileName: record.identity.name, phase: .paused,
                statusText: UploadPauseReason.interrupted.statusText, pauseReason: .interrupted,
                bytesSent: record.lastReceived, totalBytes: record.identity.size, uploadID: record.uploadID,
                hasServerSession: record.uploadID != nil, canUploadAgain: record.uploadID == nil)
        }
        for run in runs.values where !run.isBusy {
            guard let record = run.record, record.wantsToRun, record.serverOrigin == origin,
                  uploads[run.gameID]?.phase == .paused
            else { continue }
            if let uploadID = record.uploadID {
                resumeRun(run, mode: .resume(uploadID: uploadID), client: client)
            } else {
                resumeRun(run, mode: .start(candidate: nil), client: client)
            }
        }
        deleteOrphans(using: client)
    }

    /// Removes every saved upload and copy, stopping running ones (sign-out with "forget", another
    /// server). Their server sessions are not deleted.
    func removeAll() {
        for run in runs.values {
            run.stopReason = .discard
            run.task?.cancel()
            run.access = nil
        }
        runs.removeAll()
        uploads.removeAll()
        store.removeAll()
        updateActivity()
    }

    // MARK: - Progress

    /// Refreshes the bytes in flight and the speed of running uploads (the ticker calls it).
    func refreshProgress() {
        let now = monotonicSeconds()
        for (gameID, run) in runs where run.task != nil {
            guard var state = uploads[gameID] else { continue }
            let sent = min(run.progress.bytesSent, state.totalBytes)
            var speed: Double?
            if state.phase == .uploading, state.retryAttempt == nil {
                speed = run.rate.add(bytes: sent, at: now)
            }
            guard state.bytesSent != sent || state.bytesPerSecond != speed else { continue }
            state.bytesSent = sent
            state.bytesPerSecond = speed
            uploads[gameID] = state
        }
    }

    // MARK: - Running

    private func resumeRun(_ run: UploadRun, mode: UploadEngine.Mode, client: APIClient) {
        update(run.gameID) { state in
            state.phase = .preparing
            state.pauseReason = nil
            state.statusText = mode == .start(candidate: nil) ? "Starting upload…" : UploadEngine.Activity.checking.statusText
            state.hasServerSession = false
            state.canUploadAgain = false
        }
        run.stopReason = nil
        if run.file != nil {
            launch(run, mode: mode, client: client)
            return
        }
        guard let record = run.record else { return }
        // Restored after a relaunch: find the file again and check it is unchanged first (09 R17).
        run.isPreparing = true
        updateActivity()
        let store = self.store
        Task {
            let opened: Result<PreparedFilm, UploadError>
            do throws(UploadError) {
                opened = .success(try await PreparedFilm.reopen(record, store: store))
            } catch {
                opened = .failure(error)
            }
            run.isPreparing = false
            guard runs[run.gameID] === run else {
                updateActivity()
                return
            }
            if run.stopReason == .cancel {
                discardFiles(of: run)
                runs[run.gameID] = nil
                updateActivity()
                return
            }
            let reopened: PreparedFilm
            switch opened {
            case .success(let value):
                reopened = value
            case .failure(let error):
                if case .fileChanged = error, let uploadID = record.uploadID {
                    deleteSession(uploadID)
                    setRecord(run) { $0.uploadID = nil }
                }
                setRecord(run) { $0.wantsToRun = false }
                fail(run, fileName: record.identity.name, error: error, canUploadAgain: false)
                return
            }
            run.file = reopened.file
            run.access = reopened.access
            if reopened.source != record.source { setRecord(run) { $0.source = reopened.source } }
            if let reason = run.stopReason {
                stopped(run, reason: reason)
                resumeIfAsked(run)
            } else {
                launch(run, mode: mode, client: client)
            }
        }
    }

    private func launch(_ run: UploadRun, mode: UploadEngine.Mode, client: APIClient) {
        guard let file = run.file else { return }
        run.generation += 1
        let generation = run.generation
        run.stopReason = nil
        run.isCompleting = false
        run.rate.reset()
        run.progress.set(committed: run.record?.lastReceived ?? 0)
        setRecord(run) { $0.wantsToRun = true }
        let engine = UploadEngine(
            client: client, gameID: run.gameID, file: file, mode: mode, sleeper: sleeper, progress: run.progress,
            report: { [weak self, weak run] update in
                guard let self, let run, run.generation == generation else { return }
                self.apply(update, to: run)
            })
        run.task = Task { [weak self] in
            let outcome = await engine.run()
            self?.ended(run, generation: generation, outcome: outcome)
        }
        updateActivity()
        startTicker()
    }

    private func apply(_ update: UploadEngine.Update, to run: UploadRun) {
        let gameID = run.gameID
        switch update {
        case .activity(let activity):
            run.isCompleting = activity == .completing
            guard run.stopReason == nil else { return }  // already shown as paused or cancelled
            self.update(gameID) { state in
                switch activity {
                case .starting, .checking: state.phase = .preparing
                case .uploading, .retrying: state.phase = .uploading
                case .completing: state.phase = .completing
                }
                state.statusText = activity.statusText
                state.pauseReason = nil
                if case .retrying(let attempt, _) = activity {
                    state.retryAttempt = attempt
                    state.bytesPerSecond = nil
                } else {
                    state.retryAttempt = nil
                }
            }
        case .session(let session):
            setRecord(run) { record in
                record.uploadID = session.id
                record.lastReceived = session.received
            }
            self.update(gameID) { state in
                state.uploadID = session.id
                state.bytesSent = min(session.received, state.totalBytes)
            }
        case .committed(let received):
            run.record?.lastReceived = received
            self.update(gameID) { state in
                state.bytesSent = min(received, state.totalBytes)
            }
        case .abandoned(let uploadID):
            deleteSession(uploadID)
        }
    }

    private func ended(_ run: UploadRun, generation: Int, outcome: UploadEngine.Outcome) {
        guard run.generation == generation else { return }
        run.task = nil
        run.isCompleting = false
        // A Resume pressed while this run was stopping applies only when it stopped as paused.
        let resumes = run.resumeWhenStopped
        run.resumeWhenStopped = false
        defer { updateActivity() }
        if run.stopReason == .discard { return }
        let isCurrent = runs[run.gameID] === run
        if run.stopReason == .cancel || !isCurrent {
            // Cancelled (or replaced): delete the session it had or just got, and the copy.
            var uploadID = run.record?.uploadID
            if case .stopped(let id?) = outcome { uploadID = id }
            if case .blocked(_, let id?) = outcome { uploadID = id }
            if let uploadID, run.stopReason == .cancel { deleteSession(uploadID) }
            if run.stopReason == .cancel { discardFiles(of: run) }
            if isCurrent { runs[run.gameID] = nil }
            return
        }
        Self.log(outcome)
        switch outcome {
        case .finished(let result):
            finish(run, completion: UploadCompletion(gameID: run.gameID, fileName: fileName(of: run), result: result))
        case .savedWithoutAnalysis(let error):
            finish(run, completion: UploadCompletion(
                gameID: run.gameID, fileName: fileName(of: run), result: nil, analysisNotStarted: error))
        case .stopped(let uploadID):
            if let uploadID { setRecord(run) { $0.uploadID = uploadID } }
            stopped(run, reason: run.stopReason)
            if resumes { resumeStopped(run) }
        case .blocked(let error, let uploadID):
            setRecord(run) { record in
                if let uploadID { record.uploadID = uploadID }
                record.wantsToRun = true
            }
            run.stopReason = .suspend
            setPaused(run, reason: .signedOut)
            errorReporter(error)
            suspendAll()  // 09 R6: one 401 or lockout stops every upload to this server
        case .failed(let error, let fate):
            var hasServerSession = false
            var canUploadAgain = false
            switch fate {
            case .kept(let uploadID):
                setRecord(run) { record in
                    record.uploadID = uploadID
                    record.wantsToRun = false
                }
                hasServerSession = true
            case .gone, .none:
                setRecord(run) { record in
                    record.uploadID = nil
                    record.wantsToRun = false
                }
                canUploadAgain = run.file != nil
            case .refused:
                store.removeRecord(for: run.gameID)
            }
            if error is APIError { errorReporter(error) }
            fail(run, fileName: fileName(of: run), error: error, canUploadAgain: canUploadAgain, hasServerSession: hasServerSession)
        }
    }

    /// Resume was pressed while `run` was still being opened after a Pause: continue now that it has stopped.
    private func resumeIfAsked(_ run: UploadRun) {
        guard run.resumeWhenStopped else { return }
        run.resumeWhenStopped = false
        resumeStopped(run)
    }

    /// Continues a run that stopped as paused after Resume was pressed (`UploadRun.resumeWhenStopped`).
    private func resumeStopped(_ run: UploadRun) {
        guard run.stopReason == .pause, runs[run.gameID] === run else { return }
        resume(gameID: run.gameID)
    }

    /// The run stopped without an error: show it paused (or cancelled).
    private func stopped(_ run: UploadRun, reason: UploadRun.StopReason?) {
        setRecord(run) { $0.lastReceived = run.progress.committed }
        switch reason {
        case .cancel?, .discard?:
            return
        case .suspend?:
            setRecord(run) { $0.wantsToRun = true }
            setPaused(run, reason: .signedOut)
        case .background?:
            setRecord(run) { $0.wantsToRun = true }
            setPaused(run, reason: .background)
        case .pause?, nil:
            setRecord(run) { $0.wantsToRun = false }
            setPaused(run, reason: .user)
        }
    }

    private func finish(_ run: UploadRun, completion: UploadCompletion) {
        store.removeRecord(for: run.gameID)
        discardFiles(of: run)
        runs[run.gameID] = nil
        update(run.gameID) { state in
            state.phase = .finished
            state.statusText = "Upload complete - opening the game…"
            state.bytesSent = state.totalBytes
            state.bytesPerSecond = nil
            state.retryAttempt = nil
            state.completion = completion
            state.hasServerSession = false
            state.canUploadAgain = false
        }
        emit(.finished(completion))
    }

    private func fail(
        _ run: UploadRun, fileName: String, error: any PresentableError, canUploadAgain: Bool, hasServerSession: Bool = false
    ) {
        let previous = uploads[run.gameID]
        uploads[run.gameID] = UploadState(
            gameID: run.gameID, fileName: fileName, phase: .failed(error), statusText: "Stopped",
            bytesSent: run.record == nil ? 0 : (previous?.bytesSent ?? 0),
            totalBytes: run.file?.size ?? previous?.totalBytes ?? 0,
            uploadID: hasServerSession ? run.record?.uploadID : nil,
            hasServerSession: hasServerSession, canUploadAgain: canUploadAgain)
        updateActivity()
        emit(.failed(gameID: run.gameID, error: error))
    }

    private func setPaused(_ run: UploadRun, reason: UploadPauseReason) {
        update(run.gameID) { state in
            state.phase = .paused
            state.pauseReason = reason
            state.statusText = reason.statusText
            state.bytesPerSecond = nil
            state.retryAttempt = nil
            state.hasServerSession = run.record?.uploadID != nil
            state.canUploadAgain = run.record?.uploadID == nil && run.record != nil
            state.bytesSent = min(run.progress.committed, state.totalBytes)
        }
    }

    // MARK: - Background (iOS)

    private func pauseForBackground() {
        for run in runs.values where run.isBusy && !run.isCompleting {
            run.stopReason = .background
            run.resumeWhenStopped = false
            run.task?.cancel()
            setPaused(run, reason: .background)
        }
    }

    private func resumeAfterBackground() {
        guard !isSuspended, let client = clientProvider() else { return }
        for run in runs.values where !run.isBusy && uploads[run.gameID]?.pauseReason == .background {
            if let uploadID = run.record?.uploadID {
                resumeRun(run, mode: .resume(uploadID: uploadID), client: client)
            } else {
                resumeRun(run, mode: .start(candidate: nil), client: client)
            }
        }
    }

    // MARK: - Helpers

    /// Replaces the game's previous (idle) run, releasing its file.
    private func replaceRun(with run: UploadRun) {
        if let previous = runs[run.gameID] {
            previous.access = nil
            if previous.stopReason != .cancel && !previous.isBusy, uploads[run.gameID]?.phase.isOver == true {
                // A finished, failed or cancelled upload's copy is no longer needed.
                if let path = previous.copyPath, store.record(for: run.gameID)?.source != previous.record?.source {
                    store.removeCopy(path)
                }
            }
        }
        runs[run.gameID] = run
    }

    /// Deletes the app's copy of a film that `start` ignored (another upload of the game is running), unless
    /// it is the running upload's own file.
    private func discardIgnoredCopy(_ film: FilmSource, keeping current: UploadRun) {
        guard case .copied(let url) = film else { return }
        if let path = store.relativePath(ofCopy: url) {
            guard path != current.copyPath else { return }
            store.removeCopy(path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func validate(_ file: UploadFile) -> UploadError? {
        guard UploadInit(filename: file.name, size: file.size).hasAllowedExtension else {
            return .notAVideo(fileName: file.name)
        }
        guard file.size > 0 else { return .emptyFile(fileName: file.name) }
        if let limit = maxUploadBytesProvider(), limit > 0, file.size > limit {
            return .tooLarge(fileName: file.name, size: file.size, limit: limit)
        }
        return nil
    }

    private func fileName(of run: UploadRun) -> String {
        run.file?.name ?? run.record?.identity.name ?? uploads[run.gameID]?.fileName ?? ""
    }

    private func update(_ gameID: String, _ change: (inout UploadState) -> Void) {
        guard var state = uploads[gameID] else { return }
        change(&state)
        if uploads[gameID] != state { uploads[gameID] = state }
    }

    /// Changes the run's record and saves it (only while the store still has it).
    private func setRecord(_ run: UploadRun, _ change: (inout UploadRecord) -> Void) {
        guard var record = run.record else { return }
        change(&record)
        run.record = record
        if store.record(for: run.gameID) != nil { store.save(record) }
    }

    private func discardFiles(of run: UploadRun) {
        run.access = nil
        if let path = run.copyPath { store.removeCopy(path) }
    }

    private func emit(_ event: UploadEvent) {
        lastEvent = event
        for subscriber in subscribers.values { subscriber.yield(event) }
    }

    private func updateActivity() {
        activity.uploadsDidChange(running: runs.values.contains { $0.isBusy })
    }

    private func monotonicSeconds() -> Double {
        let elapsed = ContinuousClock.now - clockStart
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func startTicker() {
        guard tickerTask == nil, let interval = progressInterval else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runs.values.contains(where: { $0.task != nil }) else { break }
                self.refreshProgress()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            self?.tickerTask = nil
        }
    }

    /// How a run ended: codes only, never names or bodies (DESIGN §3).
    private static func log(_ outcome: UploadEngine.Outcome) {
        switch outcome {
        case .finished:
            logger.info("Upload finished")
        case .savedWithoutAnalysis(let error):
            logger.notice("Upload saved; analysis not queued (\(error.code, privacy: .private))")
        case .stopped:
            logger.info("Upload stopped")
        case .blocked(let error, _):
            logger.notice("Upload blocked by the server (\(error.code, privacy: .private))")
        case .failed(let error, _):
            let code = (error as? APIError)?.code ?? String(describing: type(of: error))
            logger.notice("Upload failed (\(code, privacy: .private))")
        }
    }

    private static let logger = Logger(subsystem: "org.marquettecatholic.BasketballScout", category: "uploads")

    // MARK: - Abandoned sessions (09 R20)

    /// Deletes an abandoned session now if possible, else later (it is remembered until it is gone).
    private func deleteSession(_ uploadID: String) {
        store.addOrphan(uploadID)
        guard !isSuspended, let client = clientProvider() else { return }
        deleteOrphans(using: client)
    }

    /// Sends the pending DELETEs one at a time; stops at an error that stops every request.
    private func deleteOrphans(using client: APIClient) {
        guard orphanTask == nil, !store.orphanUploadIDs.isEmpty else { return }
        let store = self.store
        orphanTask = Task { [weak self] in
            while let uploadID = store.orphanUploadIDs.first {
                do throws(APIError) {
                    try await client.deleteUpload(id: uploadID)
                    store.removeOrphan(uploadID)
                } catch {
                    if error.isNotFound {
                        store.removeOrphan(uploadID)
                        continue
                    }
                    if error.stopsAllRequests { self?.errorReporter(error) }
                    break  // try again on the next resume
                }
                if self?.isSuspended ?? true { break }
            }
            self?.orphanTask = nil
        }
    }
}
