import Foundation
import Testing
@testable import BasketballScout

/// The upload protocol end to end against `FakeUploadServer` (04 §2, §6.1; 09 D1 #8, R15–R20): chunk
/// offsets, resync after dropped connections, 409 resume points, back-off, pause/resume/cancel, the
/// commit point, relaunch, the lockout gate and the background grace period. Waits use the recording
/// sleeper (no real back-off) and the fake's held requests (no timing).
@MainActor
struct UploadManagerTests {
    /// The game of the fixtures (`upload_complete.json`).
    let gameID = "g_e934f8c21058"

    private struct Harness {
        let manager: UploadManager
        let server: FakeUploadServer
        let sleeper: RecordingSleeper
        let activity: FakeUploadActivity
        let reported: ReportedErrors
        let folder: ServiceTestFolder
        let storeDirectory: URL
    }

    private func harness(
        chunkSize: Int = 1000, reference: Data? = nil, maxUploadBytes: Int? = nil, folder: ServiceTestFolder? = nil,
        server: FakeUploadServer? = nil
    ) throws -> Harness {
        let folder = try folder ?? ServiceTestFolder()
        let server = server ?? FakeUploadServer(chunkSize: chunkSize, reference: reference)
        let storeDirectory = folder.url.appending(path: "Store", directoryHint: .isDirectory)
        let sleeper = RecordingSleeper()
        let activity = FakeUploadActivity()
        let manager = UploadManager(
            store: UploadStore(directory: storeDirectory), activity: activity, sleeper: sleeper.sleeper, progressInterval: nil)
        let client = try server.client()
        manager.clientProvider = { client }
        manager.maxUploadBytesProvider = { maxUploadBytes }
        let reported = ReportedErrors()
        manager.errorReporter = { reported.record($0) }
        return Harness(
            manager: manager, server: server, sleeper: sleeper, activity: activity, reported: reported, folder: folder,
            storeDirectory: storeDirectory)
    }

    private func phase(_ h: Harness) -> UploadPhase? { h.manager.uploads[gameID]?.phase }

    private func waitForFinish(_ h: Harness) async throws {
        try await waitUntil("the upload to finish") { phase(h) == .finished }
    }

    private func waitForHeld(_ h: Harness, count: Int = 1) async throws -> HeldReply {
        try await waitUntil("a held request") { h.server.heldReplies.count >= count && h.server.heldReplies[count - 1].isWaiting }
        return h.server.heldReplies[count - 1]
    }

    private func waitUntilIdle(_ h: Harness) async throws {
        try await waitUntil("the run to stop") { !h.activity.isRunning }
    }

    // MARK: - The happy path

    @Test func uploadsChunksOfChunkSizeAtTheReceivedOffset() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        let film = try h.folder.makeFilm(count: 2500)

        await h.manager.start(gameID: gameID, film: .external(film))
        try await waitForFinish(h)

        #expect(h.server.chunks.map(\.offset) == [0, 1000, 2000])
        #expect(h.server.chunks.map(\.length) == [1000, 1000, 500])
        #expect(h.server.chunkContentTypes.allSatisfy { $0 == "application/octet-stream" })
        #expect(h.server.everyRequestWasSignedIn)
        #expect(h.server.completeQueries == ["auto_start=true"])
        #expect(h.server.createCount == 1)
        let session = try #require(h.server.sessions.first)
        #expect(session.data == ServiceTestFolder.filmBytes(count: 2500))
        #expect(session.status == .complete)

        let body = try #require(h.server.createBodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["filename"] as? String == "Test Film.mp4")
        #expect(json["size"] as? Int == 2500)
        #expect(json["content_type"] as? String == "video/mp4")

        let state = try #require(h.manager.uploads[gameID])
        #expect(state.statusText == "Upload complete - opening the game…")
        #expect(state.bytesSent == 2500)
        #expect(state.percentText == "100.0%")
        #expect(!state.canPause && !state.canCancel && !state.canResume)
        guard case .finished(let completion)? = h.manager.lastEvent else {
            Issue.record("expected a finished event, got \(String(describing: h.manager.lastEvent))")
            return
        }
        #expect(completion.gameID == gameID)
        #expect(completion.game?.id == gameID)
        #expect(completion.job?.kind == .analyze)
        #expect(!completion.filmSavedWithoutAnalysis)
        #expect(h.manager.store.records.isEmpty)
        #expect(h.reported.errors.isEmpty)
        #expect(h.sleeper.recorded.isEmpty)
        #expect(h.activity.changes == [true, false])
        #expect(!h.manager.hasActiveUploads)
    }

    @Test func eventsReachSubscribers() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        let events = h.manager.events
        let film = try h.folder.makeFilm(count: 1200)
        await h.manager.start(gameID: gameID, film: .external(film))
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .finished(let completion)? = event else {
            Issue.record("expected finished, got \(String(describing: event))")
            return
        }
        #expect(completion.gameID == gameID)
        #expect(event?.gameID == gameID)
    }

    // MARK: - Resync and resume points (04 §2.4, §2.8)

    @Test func aConnectionDroppedAfterTheServerStoredTheChunkResyncs() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.dropAfterStoring, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitForFinish(h)

        // The chunk at 1000 arrived although the answer was lost: after the GET the next PUT starts at 2000.
        #expect(h.server.chunks.map(\.offset) == [0, 1000, 2000])
        #expect(h.sleeper.recorded == [.seconds(1)])
        let id = try #require(h.server.sessions.first?.id)
        #expect(h.server.steps.contains(.get(id)))
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func aConnectionDroppedBeforeTheChunkArrivedSendsItAgain() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.dropBeforeStoring, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitForFinish(h)

        #expect(h.server.chunks.map(\.offset) == [0, 1000, 1000, 2000])
        #expect(h.sleeper.recorded == [.seconds(1)])
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func aConflictCarryingTheServersOffsetIsAResumePointNotAFailure() async throws {
        let bytes = ServiceTestFolder.filmBytes(count: 3500)
        let h = try harness(reference: bytes)
        defer { h.folder.remove() }
        h.server.add(.conflictAhead(bytes: 1000), on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 3500)))
        try await waitForFinish(h)

        #expect(h.server.chunks.map(\.offset) == [0, 1000, 2000, 3000])
        #expect(h.sleeper.recorded.isEmpty)
        #expect(h.reported.errors.isEmpty)
        #expect(h.server.sessions.first?.data == bytes)
    }

    @Test func givesUpAfterEightRetriesWithTheWebsBackOff() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        for index in 1...9 { h.server.add(.badGateway, on: .chunk(index)) }
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitUntil("the upload to stop") { phase(h)?.error != nil }

        #expect(h.sleeper.recorded == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(h.server.chunks.count == 10)
        let state = try #require(h.manager.uploads[gameID])
        #expect(state.statusText == "Stopped")
        #expect((state.phase.error as? APIError) == .notJSON(status: 502))
        #expect(state.hasServerSession && state.canResume && !state.canUploadAgain)
        #expect(h.reported.apiErrors == [.notJSON(status: 502)])
        let record = try #require(h.manager.store.record(for: gameID))
        #expect(record.uploadID != nil)
        #expect(!record.wantsToRun)
        guard case .failed(let failedGame, _)? = h.manager.lastEvent else {
            Issue.record("expected a failed event")
            return
        }
        #expect(failedGame == gameID)

        // "Resume upload": asks the server what it has, then goes on.
        h.manager.resume(gameID: gameID)
        try await waitForFinish(h)
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func statusLinesFollowTheWeb() {
        #expect(UploadEngine.Activity.starting.statusText == "Starting upload…")
        #expect(UploadEngine.Activity.checking.statusText == "Checking what the server already has…")
        #expect(UploadEngine.Activity.uploading(reconnected: false).statusText == "Uploading…")
        #expect(UploadEngine.Activity.uploading(reconnected: true).statusText == "Reconnected - uploading…")
        #expect(UploadEngine.Activity.retrying(attempt: 3, delay: .seconds(4)).statusText
            == "Connection problem - retrying in 4 s (attempt 3 of 8)")
        #expect(UploadEngine.Activity.completing.statusText == "Finishing upload…")
        #expect(UploadPauseReason.user.statusText == "Paused")
    }

    // MARK: - Sessions the server dropped (09 R20)

    @Test func aLostSessionOffersToUploadTheSameFileAgain() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.notFound, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitUntil("the upload to stop") { phase(h)?.error != nil }

        let state = try #require(h.manager.uploads[gameID])
        #expect(state.canUploadAgain && !state.hasServerSession && !state.canResume)
        #expect((state.phase.error as? APIError)?.code == "UPLOAD_NOT_FOUND")
        #expect(h.manager.store.record(for: gameID)?.uploadID == nil)

        h.manager.restart(gameID: gameID)
        try await waitForFinish(h)
        #expect(h.server.createCount == 2)
        #expect(h.server.sessions.contains { $0.status == .complete && $0.data == ServiceTestFolder.filmBytes(count: 2500) })
    }

    @Test func aSessionAbortedWhilePausedCannotBeResumed() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)
        h.manager.pause(gameID: gameID)
        try await waitUntil("the chunk to be cancelled") { held.isCancelled }
        try await waitUntilIdle(h)
        let id = try #require(h.server.sessions.first?.id)
        h.server.abort(id)  // another film or link won meanwhile

        h.manager.resume(gameID: gameID)
        try await waitUntil("the resume to fail") { phase(h)?.error != nil }
        let state = try #require(h.manager.uploads[gameID])
        #expect(state.phase.error?.title == "This upload can't be resumed")
        #expect(state.phase.error?.message == "The server stopped this upload, so it has to start again from the beginning.")
        #expect(state.canUploadAgain)
        try await waitUntil("the aborted session to be deleted") { h.server.deletedIDs == [id] }
    }

    // MARK: - Pause, resume, cancel

    @Test func pauseAbortsTheChunkInFlightAndResumeAsksTheServerFirst() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)
        #expect(h.manager.uploads[gameID]?.canPause == true)

        h.manager.pause(gameID: gameID)
        let paused = try #require(h.manager.uploads[gameID])
        #expect(paused.phase == .paused)
        #expect(paused.pauseReason == .user)
        #expect(paused.statusText == "Paused")
        #expect(paused.canResume)
        try await waitUntil("the chunk to be cancelled") { held.isCancelled }
        try await waitUntilIdle(h)
        let record = try #require(h.manager.store.record(for: gameID))
        #expect(!record.wantsToRun)
        let id = try #require(record.uploadID)

        let before = h.server.steps.count
        h.manager.resume(gameID: gameID)
        try await waitForFinish(h)
        let after = Array(h.server.steps.dropFirst(before))
        #expect(after == [.get(id), .chunk(offset: 1000, length: 1000), .chunk(offset: 2000, length: 500), .complete(id)])
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    /// Resume right after Pause, while the cancelled chunk is still winding down: the button is not ignored.
    /// The upload shows "Checking…" at once and continues as soon as the stopped run has ended.
    @Test func resumeRightAfterPauseContinuesOnceTheRunHasStopped() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)
        let id = try #require(h.server.sessions.first?.id)

        h.manager.pause(gameID: gameID)
        #expect(h.manager.uploads[gameID]?.canResume == true)
        h.manager.resume(gameID: gameID)  // the paused run has not ended yet

        let resuming = try #require(h.manager.uploads[gameID])
        #expect(resuming.phase == .preparing)
        #expect(resuming.statusText == UploadEngine.Activity.checking.statusText)
        #expect(!resuming.canResume)
        #expect(resuming.canPause)
        try await waitUntil("the chunk to be cancelled") { held.isCancelled }
        try await waitForFinish(h)
        let steps = h.server.steps.drop { $0 != .get(id) }
        #expect(Array(steps) == [.get(id), .chunk(offset: 1000, length: 1000), .chunk(offset: 2000, length: 500), .complete(id)])
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    /// Pause, Resume and Pause again before the first stop ended: it stays paused.
    @Test func pauseAfterAPendingResumeStaysPaused() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)

        h.manager.pause(gameID: gameID)
        h.manager.resume(gameID: gameID)
        h.manager.pause(gameID: gameID)

        try await waitUntil("the chunk to be cancelled") { held.isCancelled }
        try await waitUntilIdle(h)
        try await Task.sleep(for: .milliseconds(30))
        #expect(phase(h) == .paused)
        #expect(h.manager.uploads[gameID]?.pauseReason == .user)
        #expect(h.manager.uploads[gameID]?.canResume == true)
        #expect(!h.server.steps.contains { if case .get = $0 { true } else { false } })
        #expect(h.manager.store.record(for: gameID)?.wantsToRun == false)
    }

    /// Cancel after a pending Resume: the session is deleted and nothing continues.
    @Test func cancelAfterAPendingResumeCancels() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        _ = try await waitForHeld(h)
        let id = try #require(h.server.sessions.first?.id)

        h.manager.pause(gameID: gameID)
        h.manager.resume(gameID: gameID)
        h.manager.cancel(gameID: gameID)

        #expect(phase(h) == .cancelled)
        try await waitUntil("the session to be deleted") { h.server.deletedIDs == [id] }
        try await waitUntilIdle(h)
        #expect(phase(h) == .cancelled)
        // Only the two chunks sent before the cancel (the second was held); no resync, nothing more.
        #expect(h.server.chunks.map(\.offset) == [0, 1000])
        #expect(!h.server.steps.contains { if case .get = $0 { true } else { false } })
    }

    @Test func cancelDeletesTheSessionAndTheCopy() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        let copy = try h.manager.copyDestination(forFileName: "Test Film.mov")
        try ServiceTestFolder.filmBytes(count: 2500).write(to: copy)
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .copied(copy))
        _ = try await waitForHeld(h)
        let id = try #require(h.server.sessions.first?.id)
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))

        h.manager.cancel(gameID: gameID)
        #expect(phase(h) == .cancelled)
        guard case .cancelled(let cancelledGame)? = h.manager.lastEvent else {
            Issue.record("expected a cancelled event")
            return
        }
        #expect(cancelledGame == gameID)
        try await waitUntil("the session to be deleted") { h.server.deletedIDs == [id] }
        try await waitUntil("the copy to be deleted") { !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) }
        #expect(h.manager.store.records.isEmpty)
        #expect(h.reported.errors.isEmpty)
    }

    @Test func aSessionCreatedAfterTheCancelIsDeletedWhenItArrives() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .create)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)
        h.manager.cancel(gameID: gameID)
        held.release()  // the server creates the session anyway (upload.js:199)
        try await waitUntil("the late session to be deleted") { h.server.deletedIDs.count == 1 }
        #expect(h.server.sessions.isEmpty)
        #expect(h.server.chunks.isEmpty)
        #expect(phase(h) == .cancelled)
    }

    // MARK: - complete is a commit point (04 §2.6, §8.9)

    @Test func completeCannotBePausedOrCancelled() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .complete)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        let held = try await waitForHeld(h)
        try await waitUntil("completing") { phase(h) == .completing }
        let state = try #require(h.manager.uploads[gameID])
        #expect(state.statusText == "Finishing upload…")
        #expect(!state.canPause && !state.canCancel)

        h.manager.pause(gameID: gameID)
        h.manager.cancel(gameID: gameID)
        h.manager.suspendAll()
        #expect(phase(h) == .completing)
        #expect(!held.isCancelled)

        held.release()
        try await waitForFinish(h)
        #expect(h.server.deletedIDs.isEmpty)
    }

    @Test func aLostCompleteAnswerIsRecoveredByAskingAgain() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.dropAfterStoring, on: .complete)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        try await waitForFinish(h)
        let id = try #require(h.server.sessions.first?.id)
        let tail = Array(h.server.steps.suffix(3))
        #expect(tail == [.complete(id), .get(id), .complete(id)])
        #expect(h.sleeper.recorded == [.seconds(1)])
        guard case .finished(let completion)? = h.manager.lastEvent else {
            Issue.record("expected finished")
            return
        }
        #expect(completion.result != nil)
    }

    @Test func missingBytesAtCompleteGoBackToTheChunks() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.pretendStored, on: .chunk(2))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitForFinish(h)
        #expect(h.server.chunks.map(\.offset) == [0, 1000, 2000, 2000])
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func queueUnavailableAfterCompleteStillMeansTheFilmIsSaved() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.queueUnavailable, on: .complete)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        try await waitForFinish(h)
        guard case .finished(let completion)? = h.manager.lastEvent else {
            Issue.record("expected finished")
            return
        }
        #expect(completion.result == nil)
        #expect(completion.filmSavedWithoutAnalysis)
        #expect(completion.analysisNotStarted?.code == "QUEUE_UNAVAILABLE")
        #expect(h.reported.errors.isEmpty)
        #expect(h.manager.store.records.isEmpty)
    }

    @Test func aRefusedFilmIsForgotten() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.refuseFilm, on: .complete)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        try await waitUntil("the upload to stop") { phase(h)?.error != nil }
        let state = try #require(h.manager.uploads[gameID])
        #expect((state.phase.error as? APIError)?.code == "VIDEO_INVALID")
        #expect(!state.canUploadAgain && !state.canResume)
        #expect(h.manager.store.records.isEmpty)
        #expect(h.reported.apiErrors.map(\.code) == ["VIDEO_INVALID"])
    }

    // MARK: - Same file, other file, relaunch (04 §2.8, 09 R17)

    @Test func theSameFileContinuesItsStoredSession() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        let film = try h.folder.makeFilm(count: 2500)
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(film))
        _ = try await waitForHeld(h)
        h.manager.pause(gameID: gameID)
        try await waitUntilIdle(h)

        await h.manager.start(gameID: gameID, film: .external(film))
        try await waitForFinish(h)
        #expect(h.server.createCount == 1)
        #expect(h.server.chunks.map(\.offset) == [0, 1000, 1000, 2000])
        #expect(h.server.deletedIDs.isEmpty)
    }

    @Test func anotherFileReplacesTheStoredSession() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        let first = try h.folder.makeFilm(count: 2500, seed: 0, in: "A")
        let second = try h.folder.makeFilm(count: 2500, seed: 1, in: "B")
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(first))
        _ = try await waitForHeld(h)
        let firstID = try #require(h.server.sessions.first?.id)
        h.manager.pause(gameID: gameID)
        try await waitUntilIdle(h)

        await h.manager.start(gameID: gameID, film: .external(second))
        try await waitForFinish(h)
        #expect(h.server.createCount == 2)
        try await waitUntil("the old session to be deleted") { h.server.deletedIDs == [firstID] }
        #expect(h.server.sessions.contains { $0.data == ServiceTestFolder.filmBytes(count: 2500, seed: 1) })
    }

    @Test(arguments: [false, true])
    func anInterruptedUploadContinuesAfterARelaunch(copied: Bool) async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let first = try harness(folder: folder)
        let film: FilmSource
        if copied {
            let copy = try first.manager.copyDestination(forFileName: "Test Film.mp4")
            try ServiceTestFolder.filmBytes(count: 2500).write(to: copy)
            film = .copied(copy)
        } else {
            film = .external(try folder.makeFilm(count: 2500))
        }
        first.server.add(.hold, on: .chunk(1))
        await first.manager.start(gameID: gameID, film: film)
        _ = try await waitForHeld(first)
        first.manager.suspendAll()  // stops the run; the saved record is what a killed app leaves
        try await waitUntilIdle(first)
        let saved = try #require(first.manager.store.record(for: gameID))
        #expect(saved.wantsToRun)
        let id = try #require(saved.uploadID)

        // Relaunch: a new manager on the same folder and server.
        let second = try harness(folder: folder, server: first.server)
        #expect(second.manager.uploads.isEmpty)
        second.manager.resumePendingUploads()
        try await waitForFinish(second)
        #expect(first.server.createCount == 1)
        #expect(first.server.chunks.map(\.offset) == [0, 1000, 1000, 2000])
        #expect(first.server.steps.contains(.get(id)))
        #expect(first.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
        #expect(second.manager.store.records.isEmpty)
    }

    @Test func aPausedUploadIsShownButNotStartedAfterARelaunch() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let first = try harness(folder: folder)
        first.server.add(.hold, on: .chunk(1))
        await first.manager.start(gameID: gameID, film: .external(try folder.makeFilm(count: 2500)))
        _ = try await waitForHeld(first)
        first.manager.pause(gameID: gameID)
        try await waitUntilIdle(first)

        let second = try harness(folder: folder, server: first.server)
        second.manager.resumePendingUploads()
        let restored = try #require(second.manager.uploads[gameID])
        #expect(restored.phase == .paused)
        #expect(restored.pauseReason == .interrupted)
        #expect(restored.fileName == "Test Film.mp4")
        #expect(restored.bytesSent == 1000)
        #expect(restored.canResume)
        #expect(!second.activity.isRunning)

        second.manager.resume(gameID: gameID)
        try await waitForFinish(second)
        #expect(first.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func aFileChangedSinceTheInterruptionIsNotResumed() async throws {
        let folder = try ServiceTestFolder()
        defer { folder.remove() }
        let first = try harness(folder: folder)
        let film = try folder.makeFilm(count: 2500)
        first.server.add(.hold, on: .chunk(1))
        await first.manager.start(gameID: gameID, film: .external(film))
        _ = try await waitForHeld(first)
        first.manager.suspendAll()
        try await waitUntilIdle(first)
        let id = try #require(first.manager.store.record(for: gameID)?.uploadID)
        try ServiceTestFolder.filmBytes(count: 2500, seed: 7).write(to: film)  // same size, other bytes

        let second = try harness(folder: folder, server: first.server)
        second.manager.resumePendingUploads()
        try await waitUntil("the resume to fail") { second.manager.uploads[gameID]?.phase.error != nil }
        #expect(second.manager.uploads[gameID]?.phase.error?.title == "The film file changed")
        try await waitUntil("the stale session to be deleted") { first.server.deletedIDs == [id] }
    }

    // MARK: - Lockout gate (09 R6) and background (09 R15)

    @Test func aRejectedPasswordStopsEverythingAndIsReported() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.unauthorized, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        try await waitUntil("the gate to pause it") { h.manager.uploads[gameID]?.pauseReason == .signedOut }
        try await waitUntilIdle(h)

        #expect(h.reported.apiErrors.count == 1)
        #expect(h.reported.apiErrors.first?.isAuthFailure == true)
        #expect(h.sleeper.recorded.isEmpty)  // never retried
        #expect(h.server.steps.last == .chunk(offset: 1000, length: 1000))
        #expect(h.manager.uploads[gameID]?.statusText == "Paused until you sign in again")
        #expect(h.manager.store.record(for: gameID)?.wantsToRun == true)

        // Signed in again: the gate calls resumePendingUploads().
        h.manager.resumePendingUploads()
        try await waitForFinish(h)
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func runningOutOfBackgroundTimePausesAndReturningResumes() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        let held = try await waitForHeld(h)
        #expect(h.activity.isRunning)

        h.activity.expireBackgroundTime()
        #expect(h.manager.uploads[gameID]?.pauseReason == .background)
        try await waitUntil("the chunk to be cancelled") { held.isCancelled }
        try await waitUntilIdle(h)
        #expect(h.manager.store.record(for: gameID)?.wantsToRun == true)

        h.activity.becomeActive()
        try await waitForFinish(h)
        #expect(h.activity.changes == [true, false, true, false])
    }

    @Test func returningToTheAppDoesNotResumeWhatTheCoachPaused() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 2500)))
        _ = try await waitForHeld(h)
        h.manager.pause(gameID: gameID)
        try await waitUntilIdle(h)
        h.activity.becomeActive()
        #expect(phase(h) == .paused)
        #expect(!h.activity.isRunning)
    }

    // MARK: - Checks before any request (04 §6.1)

    @Test func filesAreCheckedBeforeAnyRequest() async throws {
        let h = try harness(maxUploadBytes: 2000)
        defer { h.folder.remove() }

        await h.manager.start(gameID: "g_1", film: .external(try h.folder.makeFilm("notes.txt", count: 10)))
        let notVideo = try #require(h.manager.uploads["g_1"]?.phase.error)
        #expect(notVideo.title == "Not a video file")
        #expect(notVideo.message == "\"notes.txt\" is not an MP4, MOV or M4V video.")
        #expect(notVideo.hint == "Export the film as MP4 (Hudl: Download > MP4) and try again.")

        await h.manager.start(gameID: "g_2", film: .external(try h.folder.makeFilm("Empty.mov", count: 0)))
        let empty = try #require(h.manager.uploads["g_2"]?.phase.error)
        #expect(empty.title == "Empty file")
        #expect(empty.message == "\"Empty.mov\" is empty.")

        await h.manager.start(gameID: "g_3", film: .external(try h.folder.makeFilm("Big.M4V", count: 2500)))
        let big = try #require(h.manager.uploads["g_3"]?.phase.error)
        #expect(big.title == "File too large")
        #expect(big.message == "\"Big.M4V\" is 2.4 KB; this server accepts films up to 2.0 KB.")
        #expect(big.hint == "Trim or compress the film, or ask IT to raise SCOUT_MAX_UPLOAD_GB.")

        #expect(h.server.steps.isEmpty)
        #expect(h.manager.uploads["g_3"]?.canUploadAgain == false)
        #expect(h.reported.errors.isEmpty)
    }

    @Test func nothingIsSentWhileSignedOut() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.manager.clientProvider = { nil }
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        #expect(h.manager.uploads[gameID]?.phase.error?.title == "Not signed in")
        #expect(h.server.steps.isEmpty)
    }

    @Test func aSecondFileWhileOneUploadsIsIgnored() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        let first = try h.folder.makeFilm(count: 2500, in: "A")
        await h.manager.start(gameID: gameID, film: .external(first))
        let held = try await waitForHeld(h)
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 900, seed: 3, in: "B")))
        #expect(h.manager.uploads[gameID]?.totalBytes == 2500)
        #expect(h.server.createCount == 1)
        held.release()
        try await waitForFinish(h)
    }

    /// A copy handed over while another upload of the game runs is ignored and deleted at once (it is the
    /// manager's to delete); the running upload and its own copy are untouched.
    @Test func anIgnoredCopyIsDeletedAtOnce() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.hold, on: .chunk(1))
        let running = try h.manager.copyDestination(forFileName: "Test Film A.mov")
        try ServiceTestFolder.filmBytes(count: 2500).write(to: running)
        await h.manager.start(gameID: gameID, film: .copied(running))
        let held = try await waitForHeld(h)
        let ignored = try h.manager.copyDestination(forFileName: "Test Film B.mov")
        try ServiceTestFolder.filmBytes(count: 900, seed: 3).write(to: ignored)

        await h.manager.start(gameID: gameID, film: .copied(ignored))

        #expect(!FileManager.default.fileExists(atPath: ignored.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: ignored.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: running.path(percentEncoded: false)))
        #expect(h.manager.uploads[gameID]?.totalBytes == 2500)
        #expect(h.server.createCount == 1)
        // The same copy handed over twice (a double tap) is not deleted from under its own upload.
        await h.manager.start(gameID: gameID, film: .copied(running))
        #expect(FileManager.default.fileExists(atPath: running.path(percentEncoded: false)))
        held.release()
        try await waitForFinish(h)
        #expect(h.server.sessions.first?.data == ServiceTestFolder.filmBytes(count: 2500))
    }

    @Test func dismissForgetsAFailedUpload() async throws {
        let h = try harness()
        defer { h.folder.remove() }
        h.server.add(.reply(.json(422, FakeUploadServer.errorBody(
            code: "VALIDATION_FAILED", title: "Invalid request", message: "Some fields are invalid."))), on: .chunk(0))
        await h.manager.start(gameID: gameID, film: .external(try h.folder.makeFilm(count: 1500)))
        try await waitUntil("the upload to stop") { phase(h)?.error != nil }
        let id = try #require(h.server.sessions.first?.id)
        #expect(h.manager.uploads[gameID]?.hasServerSession == true)
        h.manager.dismiss(gameID: gameID)
        #expect(h.manager.uploads[gameID] == nil)
        #expect(h.manager.store.records.isEmpty)
        try await waitUntil("the abandoned session to be deleted") { h.server.deletedIDs == [id] }
    }
}
