import Foundation

/// One run of the chunked upload protocol for one film, off the main actor: 04 §2.8 exactly (09 D1 #8,
/// R16, R19, R20).
///
/// - Session: create one (`POST …/uploads`), or reuse/continue a known one after asking the server what
///   it has (`GET /api/uploads/{id}`).
/// - Chunks: one PUT at a time at `offset = received`, exactly `chunk_size` bytes (the last one
///   shorter), read with `FileHandle`, `application/octet-stream`. A 409 carrying `upload.received` is
///   a resume point, not a failure. Transient failures (network, -1005, HTTP ≥ 500, `retryable`) wait
///   1, 2, 4, 8, 16, 30, 30, 30 s, then resync with `GET` (8 retries in a row at most).
/// - `complete` (`auto_start=true`) is a commit point: it is not cancelled with the run, and a lost
///   answer is recovered by asking again (the server answers a completed session with the same
///   result). A 503 `QUEUE_UNAVAILABLE` there means the film WAS saved (09 R19).
/// - Cancelling the task (pause, cancel, sign-out, background) stops at once; the chunk in flight is
///   discarded by the server. A session the server created meanwhile is still reported.
/// - 401 and 429 `AUTH_THROTTLED` stop at once and are never retried (09 R6).
nonisolated struct UploadEngine: Sendable {
    nonisolated enum Mode: Sendable, Hashable {
        /// A new upload: reuse `candidate` when the server still has it open for this file (a stored
        /// session of the same file, 04 §2.8 `start`), else create a session.
        case start(candidate: String?)
        /// Continue `uploadID` (Resume, relaunch): ask the server what it has first.
        case resume(uploadID: String)
    }

    /// What the run is doing; `statusText` is the web's status line (04 §6.1).
    nonisolated enum Activity: Sendable, Hashable {
        case starting
        case checking
        case uploading(reconnected: Bool)
        case retrying(attempt: Int, delay: Duration)
        case completing

        var statusText: String {
            switch self {
            case .starting: "Starting upload…"
            case .checking: "Checking what the server already has…"
            case .uploading(let reconnected): reconnected ? "Reconnected - uploading…" : "Uploading…"
            case .retrying(let attempt, let delay):
                "Connection problem - retrying in \(delay.components.seconds) s (attempt \(attempt) of \(UploadEngine.maximumRetries))"
            case .completing: "Finishing upload…"
            }
        }
    }

    nonisolated enum Update: Sendable {
        case activity(Activity)
        /// The session in use (created, reused or checked): persist its id.
        case session(UploadSession)
        /// The server has this many bytes (after a chunk, a 409 or a resync).
        case committed(Int)
        /// A session this run will not use: delete it on the server (09 R20).
        case abandoned(uploadID: String)
    }

    /// What became of the server's session when a run failed.
    nonisolated enum SessionFate: Sendable, Hashable {
        /// Still open with the part already sent: offer "Resume upload".
        case kept(uploadID: String)
        /// The server no longer has it (deleted, expired, aborted because another film or link won):
        /// the same file can be sent again from byte 0 ("Upload this file again", 09 R20).
        case gone
        /// The server refused the film itself (not a video, too long): choose another file.
        case refused
        /// No session was created.
        case none
    }

    nonisolated enum Outcome: Sendable {
        /// The film is saved and its analysis queued.
        case finished(FilmResult)
        /// The film is saved but the job queue refused the analysis (503 `QUEUE_UNAVAILABLE`, 09 R19).
        case savedWithoutAnalysis(APIError)
        /// The task was cancelled. `uploadID`: the session, if one exists.
        case stopped(uploadID: String?)
        /// A 401, 429 `AUTH_THROTTLED` or other error that stops every request (09 R6).
        case blocked(APIError, uploadID: String?)
        case failed(any PresentableError, SessionFate)
    }

    /// Transient failures in a row before giving up (upload.js `MAX_RETRIES`).
    static let maximumRetries = 8

    /// Codes after which the server will not take this film at all (upload.js `FILM_REFUSED`).
    static let filmRefusedCodes: Set<String> = [ErrorCode.videoInvalid, ErrorCode.videoDecodeFailed, ErrorCode.videoTooLong]

    /// Chunk length when a server announces none (never happens with Basketball Scout).
    static let fallbackChunkSize = 16 * 1024 * 1024

    /// The wait before retry `attempt` (1-based): 1, 2, 4, 8, 16, 30, 30, 30 s.
    static func backoff(attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(max(attempt - 1, 0), 5)))
    }

    /// A failure worth retrying (upload.js `isTransient`): network errors, HTTP ≥ 500, or `retryable`.
    /// Never a cancellation or an error that stops every request.
    static func isTransient(_ error: APIError) -> Bool {
        if error.isCancellation || error.stopsAllRequests { return false }
        if let status = error.status, status >= 500 { return true }
        return error.isRetryable
    }

    let client: APIClient
    let gameID: String
    let file: UploadFile
    let mode: Mode
    let sleeper: Sleeper
    let progress: UploadProgress
    let report: @MainActor @Sendable (Update) -> Void

    // MARK: - Running

    @concurrent
    func run() async -> Outcome {
        let reader: UploadChunkReader
        do {
            reader = try UploadChunkReader(url: file.url)
        } catch {
            if case .resume(let uploadID) = mode { return .failed(UploadError.fileUnavailable(fileName: file.name), .kept(uploadID: uploadID)) }
            return .failed(UploadError.fileUnavailable(fileName: file.name), .none)
        }
        var failures = 0
        var session: UploadSession
        switch await openSession(failures: &failures) {
        case .session(let opened): session = opened
        case .outcome(let outcome): return outcome
        }
        while true {
            if let outcome = await sendChunks(&session, reader: reader, failures: &failures) { return outcome }
            switch await complete(&session, failures: &failures) {
            case .outcome(let outcome): return outcome
            case .moreBytes: continue
            }
        }
    }

    // MARK: - Session

    private enum Opened {
        case session(UploadSession)
        case outcome(Outcome)
    }

    private func openSession(failures: inout Int) async -> Opened {
        switch mode {
        case .start(let candidate):
            await report(.activity(.starting))
            if let candidate {
                do {
                    let existing = try await client.upload(id: candidate)
                    if existing.size == file.size, existing.status == .open || existing.status == .complete {
                        await adopt(existing)
                        return .session(existing)
                    }
                    await report(.abandoned(uploadID: candidate))
                } catch {
                    if error.isCancellation { return .outcome(.stopped(uploadID: candidate)) }
                    if error.stopsAllRequests { return .outcome(.blocked(error, uploadID: candidate)) }
                    // 04 §2.8: any other error, start fresh. A session that may still exist is deleted later.
                    if !error.isNotFound { await report(.abandoned(uploadID: candidate)) }
                }
            }
            if Task.isCancelled { return .outcome(.stopped(uploadID: nil)) }
            return await createSession(failures: &failures)
        case .resume(let uploadID):
            await report(.activity(.checking))
            return await checkSession(uploadID, failures: &failures)
        }
    }

    private func createSession(failures: inout Int) async -> Opened {
        let body = UploadInit(filename: file.name, size: file.size, contentType: file.contentType)
        let client = self.client
        let gameID = self.gameID
        while true {
            // Not cancelled with the run: a session the server made must reach the manager, which deletes
            // it when the coach cancelled meanwhile (upload.js:199).
            let result = await Self.uncancellable { () async throws(APIError) -> UploadSession in
                try await client.createUpload(gameID: gameID, body)
            }
            switch result {
            case .success(let session):
                await adopt(session)
                if Task.isCancelled { return .outcome(.stopped(uploadID: session.id)) }
                return .session(session)
            case .failure(let error):
                if error.isCancellation { return .outcome(.stopped(uploadID: nil)) }
                if error.stopsAllRequests { return .outcome(.blocked(error, uploadID: nil)) }
                guard Self.isTransient(error), failures < Self.maximumRetries else { return .outcome(.failed(error, .none)) }
                failures += 1
                if await !wait(attempt: failures) { return .outcome(.stopped(uploadID: nil)) }
                await report(.activity(.starting))
            }
        }
    }

    /// Resume: what does the server have? (upload.js:338-363)
    private func checkSession(_ uploadID: String, failures: inout Int) async -> Opened {
        while true {
            do {
                let current = try await client.upload(id: uploadID)
                guard current.size == file.size, current.status == .open || current.status == .complete else {
                    // Aborted (another film or link won, or the film was refused while offline): over.
                    await report(.abandoned(uploadID: uploadID))
                    return .outcome(.failed(UploadError.cannotResume, .gone))
                }
                await adopt(current)
                return .session(current)
            } catch {
                if error.isCancellation { return .outcome(.stopped(uploadID: uploadID)) }
                if error.stopsAllRequests { return .outcome(.blocked(error, uploadID: uploadID)) }
                if error.code == ErrorCode.uploadNotFound { return .outcome(.failed(error, .gone)) }
                guard Self.isTransient(error), failures < Self.maximumRetries else {
                    return .outcome(.failed(error, .kept(uploadID: uploadID)))
                }
                failures += 1
                if await !wait(attempt: failures) { return .outcome(.stopped(uploadID: uploadID)) }
                await report(.activity(.checking))
            }
        }
    }

    // MARK: - Chunks

    /// Sends chunks until the server has every byte (or says the session is complete). Nil = go on to
    /// `complete`.
    private func sendChunks(_ session: inout UploadSession, reader: UploadChunkReader, failures: inout Int) async -> Outcome? {
        while session.status != .complete && session.received < file.size {
            if Task.isCancelled { return .stopped(uploadID: session.id) }
            let offset = session.received
            let chunkSize = session.chunkSize > 0 ? session.chunkSize : Self.fallbackChunkSize
            let length = min(chunkSize, file.size - offset)
            await report(.activity(.uploading(reconnected: failures > 0)))
            let data: Data
            do {
                data = try reader.read(offset: offset, length: length)
            } catch is UploadChunkReader.ShortRead {
                await report(.abandoned(uploadID: session.id))
                return .failed(UploadError.fileChanged(fileName: file.name), .gone)
            } catch {
                return .failed(UploadError.fileUnavailable(fileName: file.name), .kept(uploadID: session.id))
            }
            do {
                let updated = try await client.uploadChunk(
                    uploadID: session.id, offset: offset, data: data, progress: progress.beginChunk())
                failures = 0
                session = updated
                progress.set(committed: updated.received)
                await report(.committed(updated.received))
            } catch {
                progress.set(committed: session.received)
                if error.isCancellation { return .stopped(uploadID: session.id) }
                if error.stopsAllRequests { return .blocked(error, uploadID: session.id) }
                if error.status == 409, let current = error.upload, current.received != offset || current.status != .open {
                    // 04 §2.4: the server says where to go on (offset conflict). Not a failure.
                    if let outcome = await take(current, into: &session) { return outcome }
                    continue
                }
                if error.code == ErrorCode.uploadNotFound { return .failed(error, .gone) }
                if error.status == 409, error.upload == nil {
                    // "This upload is already complete/aborted": ask which.
                    if let outcome = await recheck(&session, after: error, offset: offset) { return outcome }
                    continue
                }
                // Transient, including the idle-chunk 409 UPLOAD_INCOMPLETE that leaves the offset unchanged.
                guard Self.isTransient(error), failures < Self.maximumRetries else {
                    return .failed(error, .kept(uploadID: session.id))
                }
                failures += 1
                if await !wait(attempt: failures) { return .stopped(uploadID: session.id) }
                // Resync: the chunk may or may not have arrived (04 §8.6). Errors are ignored here; the
                // next chunk then fails and backs off again.
                do {
                    let current = try await client.upload(id: session.id)
                    if let outcome = await take(current, into: &session) { return outcome }
                } catch {
                    if error.isCancellation { return .stopped(uploadID: session.id) }
                    if error.stopsAllRequests { return .blocked(error, uploadID: session.id) }
                    if error.code == ErrorCode.uploadNotFound { return .failed(error, .gone) }
                }
            }
        }
        return nil
    }

    /// After a 409 without a resume point: the session's status decides (complete → `complete`,
    /// aborted → over, open with progress → go on).
    private func recheck(_ session: inout UploadSession, after conflict: APIError, offset: Int) async -> Outcome? {
        do {
            let current = try await client.upload(id: session.id)
            if current.status == .open && current.received == offset {
                // Nothing moved: this conflict is not about the offset; do not loop on it.
                return .failed(conflict, .kept(uploadID: session.id))
            }
            return await take(current, into: &session)
        } catch {
            if error.isCancellation { return .stopped(uploadID: session.id) }
            if error.stopsAllRequests { return .blocked(error, uploadID: session.id) }
            if error.code == ErrorCode.uploadNotFound { return .failed(error, .gone) }
            return .failed(conflict, .kept(uploadID: session.id))
        }
    }

    /// Takes the server's view of the session; an outcome when the session is over.
    private func take(_ current: UploadSession, into session: inout UploadSession) async -> Outcome? {
        guard current.size == file.size, current.status == .open || current.status == .complete else {
            await report(.abandoned(uploadID: current.id))
            return .failed(UploadError.cannotResume, .gone)
        }
        session = current
        progress.set(committed: current.received)
        await report(.committed(current.received))
        return nil
    }

    // MARK: - Complete (commit point)

    private enum Completed {
        case outcome(Outcome)
        /// The server is missing bytes: back to the chunks.
        case moreBytes
    }

    private func complete(_ session: inout UploadSession, failures: inout Int) async -> Completed {
        await report(.activity(.completing))
        let client = self.client
        let uploadID = session.id
        // Paused or cancelled just before: do not commit after all.
        if Task.isCancelled { return .outcome(.stopped(uploadID: uploadID)) }
        var conflictChecks = 0
        while true {
            let result = await Self.uncancellable { () async throws(APIError) -> FilmResult in
                try await client.completeUpload(id: uploadID, autoStart: true)
            }
            let error: APIError
            switch result {
            case .success(let film): return .outcome(.finished(film))
            case .failure(let failure): error = failure
            }
            // 09 R19: the film is saved; only the analysis job could not be queued.
            if error.code == ErrorCode.queueUnavailable { return .outcome(.savedWithoutAnalysis(error)) }
            if error.stopsAllRequests { return .outcome(.blocked(error, uploadID: uploadID)) }
            if error.isCancellation { return .outcome(.stopped(uploadID: uploadID)) }
            if error.code == ErrorCode.uploadNotFound { return .outcome(.failed(error, .gone)) }
            if Self.filmRefusedCodes.contains(error.code) { return .outcome(.failed(error, .refused)) }

            let transient = error.status != 409 && Self.isTransient(error)
            if transient {
                guard failures < Self.maximumRetries else { return .outcome(.failed(error, .kept(uploadID: uploadID))) }
                failures += 1
                if await !wait(attempt: failures) { return .outcome(.stopped(uploadID: uploadID)) }
            } else if error.status != 409 || conflictChecks >= 3 {
                return .outcome(.failed(error, .kept(uploadID: uploadID)))
            } else {
                conflictChecks += 1
            }
            // Where does the session stand? (UPLOAD_INCOMPLETE, "already aborted", a lost answer.)
            let current: UploadSession
            do {
                current = try await client.upload(id: uploadID)
            } catch let check {
                if check.isCancellation { return .outcome(.stopped(uploadID: uploadID)) }
                if check.stopsAllRequests { return .outcome(.blocked(check, uploadID: uploadID)) }
                if check.code == ErrorCode.uploadNotFound { return .outcome(.failed(check, .gone)) }
                if transient {
                    await report(.activity(.completing))
                    continue
                }
                return .outcome(.failed(error, .kept(uploadID: uploadID)))
            }
            guard current.size == file.size, current.status == .open || current.status == .complete else {
                // Another film or link won (09 R20).
                await report(.abandoned(uploadID: uploadID))
                return .outcome(.failed(UploadError.cannotResume, .gone))
            }
            if current.status == .open && current.received < file.size {
                session = current
                progress.set(committed: current.received)
                await report(.committed(current.received))
                return .moreBytes
            }
            if current.status == .open && !transient {
                // Every byte is there but the server said no, e.g. "This game's film is being analysed
                // right now.": the session stays; Resume calls `complete` again later.
                return .outcome(.failed(error, .kept(uploadID: uploadID)))
            }
            // Complete already (the answer was lost), or a transient failure: ask again (idempotent).
            await report(.activity(.completing))
        }
    }

    // MARK: - Helpers

    /// Reports the session in use.
    private func adopt(_ session: UploadSession) async {
        progress.set(committed: session.received)
        await report(.session(session))
    }

    /// Waits before retry `attempt`, showing the countdown text. False when the run was cancelled.
    private func wait(attempt: Int) async -> Bool {
        let delay = Self.backoff(attempt: attempt)
        await report(.activity(.retrying(attempt: attempt, delay: delay)))
        do {
            try await sleeper.sleep(for: delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Runs `operation` in its own task, so cancelling the run does not cancel the request (session
    /// creation and the `complete` commit point).
    private static func uncancellable<T: Sendable>(
        _ operation: @escaping @Sendable () async throws(APIError) -> T
    ) async -> Result<T, APIError> {
        await Task { () async -> Result<T, APIError> in
            do throws(APIError) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
