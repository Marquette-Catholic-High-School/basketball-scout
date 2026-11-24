#if os(macOS)
import Foundation
import Testing
@testable import BasketballScout

/// The Mac's capture of a live game against a scripted server and a stand-in ffmpeg (docs/LIVE.md "What a
/// capture client does"): the order of the calls, sending the parts in order, what is retried and what is
/// left out, the stream dropping, "End live game", and a game that stops taking film.
@MainActor
struct LiveCaptureControllerTests {
    private typealias Call = FakeLiveAPI.Call

    /// Starts a capture and returns it with its first ffmpeg.
    private func started(_ h: LiveCaptureHarness) async throws -> (LiveCaptureController, FakeLiveProcess) {
        let capture = try h.capture()
        try await capture.start()
        return (capture, try await h.process())
    }

    private func ended(_ capture: LiveCaptureController) async throws {
        try await waitUntil("the capture to end") { !capture.isActive }
    }

    // MARK: - Start

    @Test func startAsksTheServerFirstThenRunsFFmpegWithItsPartLength() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        h.api.set(segmentSeconds: 90)
        let capture = try h.capture()
        #expect(capture.phase == .starting)

        try await capture.start()
        let process = try await h.process()

        #expect(h.api.calls == [.start])  // once, without a part length of its own
        #expect(h.launcher.executables == [LiveCaptureHarness.ffmpeg])
        #expect(process.segmentSeconds == 90)
        #expect(process.startNumber == 0)
        #expect(process.inputLink == LiveCaptureHarness.linkText)
        #expect(process.listFile.lastPathComponent == "parts-0.csv")
        #expect(process.arguments.last == h.folder.url.path(percentEncoded: false) + "part-%05d.mp4")
        #expect(h.statuses.count == 1)  // the game page hears that the game is live
        #expect(h.keepAwake.isAwake)
        #expect(capture.phase == .starting)  // nothing received yet

        try process.beginPart(0)
        try await waitUntil("the first bytes") { capture.phase == .capturing }
        await capture.suspend()
        #expect(!h.keepAwake.isAwake)
    }

    @Test func aRefusedStartThrowsAndStartsNothing() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        h.api.fail(.start, with: FakeLiveAPI.serverError(409, code: ErrorCode.conflict, title: "Conflict"))
        let capture = try h.capture()

        await #expect(throws: APIError.self) { try await capture.start() }

        #expect(capture.phase == .ended(.failed))
        #expect(capture.failure?.title == "Conflict")
        #expect(h.launcher.processes.isEmpty)
        #expect(!h.keepAwake.isAwake)
        #expect(h.files.isEmpty)
    }

    @Test func aStartOnAGameThatHasEndedSaysSo() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        h.api.stopTakingFilm()
        let capture = try h.capture()

        await #expect(throws: APIError.self) { try await capture.start() }

        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(h.launcher.processes.isEmpty)
    }

    @Test func ffmpegThatCannotBeStartedEndsTheCaptureWithAReason() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        h.launcher.failToLaunch()
        let capture = try h.capture()

        try await capture.start()
        try await ended(capture)

        #expect(capture.phase == .ended(.failed))
        #expect(capture.failure?.title == "ffmpeg could not be started")
        #expect(h.api.count(.finish) == 0)  // the game stays live: the capture can be started again
        #expect(!h.keepAwake.isAwake)
    }

    // MARK: - Sending the parts

    @Test func finishedPartsAreSentInOrderOneAtATimeAndDeletedAfterComplete() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)

        // Three parts are finished before the first is on the server.
        let sent = try (0..<3).map { try process.finishPart($0, bytes: 2500, length: 120.0 + Double($0)) }
        try await waitUntil("three parts on the server") { capture.partsSent == 3 }

        // Each part: its session, its bytes in the server's chunk size from where the server stands, complete.
        var expected: [Call] = [.start]
        for index in 0..<3 {
            expected += [
                .create(index: index), .chunk(index: index, offset: 0, count: 1000), .chunk(index: index, offset: 1000, count: 1000),
                .chunk(index: index, offset: 2000, count: 500), .complete(index: index),
            ]
        }
        #expect(h.api.calls == expected)
        #expect(h.api.parts == [0: sent[0], 1: sent[1], 2: sent[2]])
        // The length is end − start of the list's line.
        #expect(h.api.durations == [0: 120, 1: 121, 2: 122])
        // Only the list is left: a part is deleted once `complete` answered.
        #expect(h.files == ["parts-0.csv"])
        #expect(capture.partsCaptured == 3 && capture.partsWaiting == 0 && capture.partsNotAccepted == 0)
        #expect(capture.phase == .capturing)
        #expect(capture.waitingNote == nil)
        await capture.suspend()
    }

    @Test func aPartIsNotSentBeforeItsLineIsInTheList() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)

        try process.beginPart(0)
        // A line that is still being written (no line end yet) does not count either.
        try process.appendToList("part-00000.mp4,0.000000,120.1")
        try await waitUntil("capturing") { capture.phase == .capturing }
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.api.count(.create) == 0)
        #expect(capture.partsCaptured == 0)

        try process.appendToList("33333\n")
        try await waitUntil("the part on the server") { capture.partsSent == 1 }
        #expect(h.api.durations[0] == 120.133333)
        await capture.suspend()
    }

    @Test func aPartTheServerAlreadyHasIsSkippedAndDeleted() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        // Part 0 reached the server before the app was quit; its file is still here.
        h.api.alreadyHas(0)
        try h.folder.create()
        let earlier = FakeLiveProcess(
            arguments: ["-segment_list", h.folder.fileURL("parts-0.csv").path(percentEncoded: false)], directory: h.folder.url)
        try earlier.finishPart(0)
        let (capture, process) = try await started(h)

        try await waitUntil("part 0 settled") { capture.partsSent == 1 }

        // `status == complete` on create: nothing is sent, the local copy goes.
        #expect(h.api.calls == [.start, .create(index: 0)])
        #expect(!h.files.contains("part-00000.mp4"))
        // ffmpeg carries on after the parts the server has, with a list of its own.
        #expect(process.startNumber == 1)
        #expect(process.listFile.lastPathComponent == "parts-1.csv")
        await capture.suspend()
    }

    @Test func aHalfSentPartContinuesFromWhatTheServerHas() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let whole = FakeLiveProcess.bytes(index: 0, count: 2500)
        h.api.hasFirstBytes(of: 0, whole.prefix(1200))
        let (capture, process) = try await started(h)

        try process.finishPart(0, bytes: 2500)
        try await waitUntil("the part on the server") { capture.partsSent == 1 }

        #expect(h.api.calls == [
            .start, .create(index: 0), .chunk(index: 0, offset: 1200, count: 1000), .chunk(index: 0, offset: 2200, count: 300),
            .complete(index: 0),
        ])
        #expect(h.api.parts[0] == whole)
        await capture.suspend()
    }

    @Test func aChunkTheServerWantsFromAnotherByteResumesFromItsReceived() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        // The first chunk arrived, but its answer was lost; the server then says where it stands (409 with the session).
        let stands = UploadSession(
            id: "u_0_1", gameID: h.gameID, filename: "part-00000.mp4", size: 2500, received: 1000, chunkSize: 1000,
            status: .open, liveSegment: 0, liveDurationS: 120, createdAt: nil, updatedAt: nil)
        h.api.fail(.chunk, with: FakeLiveAPI.serverError(409, code: ErrorCode.conflict, title: "Conflict", upload: stands))

        try process.finishPart(0, bytes: 2500)
        try await waitUntil("the part to be asked about") { h.api.count(.chunk) >= 1 }
        try await waitUntil("the part on the server") { capture.partsSent == 1 }
        await capture.suspend()

        // It did not start over, wait, or give the part up: the next chunk starts at the server's byte.
        let chunks = h.api.calls.filter { FakeLiveAPI.step(of: $0) == .chunk }
        #expect(chunks.first == .chunk(index: 0, offset: 0, count: 1000))
        #expect(chunks.dropFirst().first == .chunk(index: 0, offset: 1000, count: 1000))
        #expect(h.api.count(.create) == 1)
        #expect(!h.sleeper.recorded.contains(.seconds(1)))
    }

    // MARK: - What is retried, and what is left out

    @Test func networkTroubleIsRetriedForeverWithACappedBackoffWhileTheGameIsRecorded() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        // Offline, a timeout, the server down (5xx), "slow down" (429), a proxy's error page, a sign-in page of
        // the gym's Wi-Fi: none of them is the server turning the part down.
        h.api.fail(
            .create, with: FakeLiveAPI.offline, .transport(URLError(.timedOut)),
            FakeLiveAPI.serverError(503, code: ErrorCode.queueUnavailable, title: "Queue unavailable"),
            FakeLiveAPI.serverError(429, code: "RATE_LIMITED", title: "Too many requests"),
            .notJSON(status: 502), .notJSON(status: 302), .decoding(status: 200, detail: "$"),
            .transport(URLError(.serverCertificateUntrusted)), FakeLiveAPI.offline, FakeLiveAPI.offline)

        try process.finishPart(0)
        try await waitUntil("the part on the server") { capture.partsSent == 1 }

        #expect(h.api.count(.create) == 11)
        // 1, 2, 4, 8, 16, then 30 s for as long as it takes: no limit as for a film upload.
        let waits = h.sleeper.recorded.filter { $0 != LiveTestTiming.firstStatusCheck }
        #expect(waits == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30].map { Duration.seconds($0) })
        #expect(process.interrupts == 0)  // ffmpeg went on recording all the while
        #expect(capture.waitingNote == nil)
        #expect(h.files == ["parts-0.csv"])
        await capture.suspend()
    }

    @Test func whileTheNetworkIsDownThePanelSaysHowManyPartsWait() async throws {
        let sleeper = LiveTestSleeper()
        sleeper.hold(.seconds(1))
        let h = try LiveCaptureHarness(sleeper: sleeper)
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        h.api.fail(.create, with: FakeLiveAPI.offline)

        try process.finishPart(0)
        try await waitUntil("the back-off") { sleeper.waitingCount(.seconds(1)) == 1 }
        #expect(capture.waitingNote == "Waiting for the network: 1 part to send")
        #expect(capture.lastProblem != nil)
        try process.finishPart(1)
        try process.finishPart(2)
        try await waitUntil("more parts waiting") { capture.partsWaiting == 3 }
        #expect(capture.partsCaptured == 3 && capture.partsSent == 0)
        // Nothing was deleted: the parts wait on this Mac.
        #expect(h.files == ["part-00000.mp4", "part-00001.mp4", "part-00002.mp4", "parts-0.csv"])

        sleeper.release(.seconds(1))
        try await waitUntil("everything sent") { capture.partsSent == 3 }
        #expect(capture.waitingNote == nil)
        #expect(h.api.parts.keys.sorted() == [0, 1, 2])
        await capture.suspend()
    }

    @Test func aPartTheServerTurnsDownIsKeptAndLeftOutAndTheNextOnesAreStillSent() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        // Part 0 is too large (413 on its session), part 1 is not a video (422 on complete).
        h.api.fail(.create, with: FakeLiveAPI.serverError(413, code: ErrorCode.uploadTooLarge, title: "Film too large"))
        h.api.fail(.complete, with: FakeLiveAPI.serverError(422, code: ErrorCode.videoInvalid, title: "Not a video file"))

        try process.finishPart(0)
        try process.finishPart(1)
        let third = try process.finishPart(2)
        try await waitUntil("part 2 on the server") { capture.partsSent == 1 }

        #expect(h.api.parts == [2: third])
        #expect(capture.partsNotAccepted == 2)
        #expect(capture.partsCaptured == 3 && capture.partsWaiting == 0)
        #expect(capture.lastProblem == "Part 2 was not accepted by the server: Not a video file")
        // Kept on this Mac under another name, so they are not sent again; nothing was retried or waited for.
        #expect(h.files == ["part-00000.refused.mp4", "part-00001.refused.mp4", "parts-0.csv"])
        #expect(h.api.count(.create) == 3)
        #expect(!h.sleeper.recorded.contains(.seconds(1)))
        #expect(process.interrupts == 0)
        await capture.suspend()
    }

    @Test func anEmptyPartIsNeverSent() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)

        try process.finishPart(0, bytes: 0)
        let second = try process.finishPart(1)
        try await waitUntil("part 1 on the server") { capture.partsSent == 1 }

        #expect(h.api.calls == [
            .start, .create(index: 1), .chunk(index: 1, offset: 0, count: 1000), .chunk(index: 1, offset: 1000, count: 1000),
            .chunk(index: 1, offset: 2000, count: 500), .complete(index: 1),
        ])
        #expect(h.api.parts == [1: second])
        #expect(capture.partsNotAccepted == 1)
        #expect(capture.lastProblem == "Part 1 is empty or could not be read, so it was not sent.")
        await capture.suspend()
    }

    @Test func aRejectedPasswordIsReportedOnceAndNeverRetriedWhileFFmpegKeepsRecording() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        h.api.fail(.create, with: .unauthorized(nil))

        try process.finishPart(0)
        try await waitUntil("the 401 at the lockout gate") { h.reported.count == 1 }
        // The session still hands out the same client (the gate has not dropped it yet in this test): the
        // capture must not use it again, however long it waits.
        try await waitUntil("a few looks for a new sign-in") { h.sleeper.recorded.filter { $0 == LiveTestTiming.signInCheck }.count >= 5 }

        #expect(h.reported == [.unauthorized(nil)])
        #expect(h.api.count(.create) == 1)
        #expect(capture.waitingNote == "Waiting for you to sign in: 1 part to send")
        #expect(process.interrupts == 0 && capture.isActive)
        try process.finishPart(1)
        try await waitUntil("the next part waiting") { capture.partsWaiting == 2 }

        // The coach signed in again: a new client, and sending carries on in order.
        let fresh = FakeLiveAPI(gameID: h.gameID)
        h.currentAPI = fresh
        try await waitUntil("both parts on the server") { capture.partsSent == 2 }
        #expect(fresh.parts.keys.sorted() == [0, 1])
        #expect(h.api.count(.create) == 1)
        #expect(capture.waitingNote == nil)
        await capture.suspend()
    }

    @Test func whileSignedOutThePartsWait() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        h.currentAPI = nil

        try process.finishPart(0)
        try await waitUntil("the part waiting") { capture.waitingNote == "Waiting for you to sign in: 1 part to send" }
        #expect(h.api.count(.create) == 0)

        h.currentAPI = h.api
        try await waitUntil("the part on the server") { capture.partsSent == 1 }
        await capture.suspend()
    }

    // MARK: - The stream drops

    @Test func whenFFmpegExitsItIsStartedAgainWithTheNextPartNumber() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, first) = try await started(h)
        try first.finishPart(0)
        try first.finishPart(1)
        try first.beginPart(2)  // cut off in the middle: never listed
        first.say(
            "[rtmp @ 0x600003e1c000] Cannot read RTMP handshake response",
            "[in#0 @ 0x600001c0c000] Error opening input: Input/output error",
            "Error opening input file rtmp://192.168.1.50/live/secretkey123.")

        first.exit(1)
        let second = try await h.process(1)

        // The camera or the Wi-Fi dropped: the next run numbers on after the last finished part, with its own list.
        #expect(second.startNumber == 2)
        #expect(second.listFile.lastPathComponent == "parts-1.csv")
        #expect(h.sleeper.recorded.contains(LiveTestTiming.reconnect(1)))
        #expect(capture.phase == .reconnecting)
        // ffmpeg's last words, without the link or its key.
        let problem = try #require(capture.lastProblem)
        #expect(problem == "Error opening input file the stream.")
        #expect(!problem.contains("secretkey123") && !problem.contains("192.168.1.50"))
        #expect(first.interrupts == 0 && h.api.count(.finish) == 0)

        try second.finishPart(2)
        try second.finishPart(3)
        try await waitUntil("four parts on the server") { capture.partsSent == 4 }
        #expect(capture.phase == .capturing)
        #expect(h.api.parts.keys.sorted() == [0, 1, 2, 3])
        // The second run's part 2 replaced the first run's unfinished one.
        #expect(h.api.parts[2] == FakeLiveProcess.bytes(index: 2, count: 2500))

        // It keeps trying for as long as the stream stays away, a little slower each time.
        second.exit(1)
        let third = try await h.process(2)
        #expect(third.startNumber == 4)
        third.exit(1)
        let fourth = try await h.process(3)
        #expect(fourth.startNumber == 4)
        // The run before it finished no part, so it left no list: the name is free again.
        #expect(third.listFile.lastPathComponent == "parts-2.csv" && fourth.listFile.lastPathComponent == "parts-2.csv")
        #expect(h.sleeper.recorded.filter { $0 >= .seconds(61) } == [1, 1, 2].map { LiveTestTiming.reconnect($0) })
        await capture.suspend()
    }

    @Test func theReconnectPauseAndTheSendingBackoffAreWhatTheAppShips() {
        let timing = LiveCaptureTiming.standard
        #expect((1...6).map { timing.reconnectDelay($0) } == [3, 3, 5, 10, 15, 15].map { Duration.seconds($0) })
        #expect((1...8).map { timing.backoff($0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(timing.listPoll == .seconds(1))
        #expect(timing.exitGrace == .seconds(10))
        #expect(timing.firstStatusCheck == .seconds(3))
        #expect(timing.statusCheck == .seconds(10))
    }

    @Test func capturingAgainAfterTheServerAlreadyHasPartsNumbersOnFromThem() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        // Another Mac (or an earlier run whose folder is gone) sent parts 0 to 2.
        h.api.alreadyHas(0, 1, 2)

        let (capture, process) = try await started(h)

        #expect(process.startNumber == 3)
        await capture.suspend()
    }

    // MARK: - End live game

    @Test func endInterruptsFFmpegSendsTheRestAndOnlyThenTellsTheServer() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        try process.beginPart(1)
        // Interrupted, ffmpeg closes the part it is writing, lists it and exits.
        process.onInterrupt { process in
            _ = try? process.finishPart(1, bytes: 700, length: 31.5)
            process.exit(255)
        }

        capture.end()
        #expect(capture.phase == .finishing)
        try await ended(capture)

        #expect(process.interrupts == 1 && process.terminations == 0)
        #expect(capture.phase == .ended(.finished))
        #expect(h.api.parts.keys.sorted() == [0, 1])
        #expect(h.api.durations[1] == 31.5)
        // `finish` comes last, after the last part's `complete`.
        #expect(Array(h.api.calls.suffix(4)) == [.create(index: 1), .chunk(index: 1, offset: 0, count: 700), .complete(index: 1), .finish])
        #expect(h.api.count(.finish) == 1)
        #expect(h.api.liveState == .finishing)
        #expect(h.launcher.processes.count == 1)  // not started again
        #expect(capture.partsSent == 2 && capture.partsWaiting == 0)
        // Nothing is left on this Mac, and it may sleep again.
        #expect(!h.folder.exists)
        #expect(!h.keepAwake.isAwake)
        #expect(h.statuses.last?.game.live?.state == .finishing)
    }

    @Test func ffmpegThatDoesNotExitIsKilledAfterTheGrace() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        process.onInterrupt { _ in }  // it hangs

        capture.end()
        try await waitUntil("the grace period") { h.sleeper.waitingCount(LiveTestTiming.exitGrace) == 1 }
        #expect(process.interrupts == 1 && process.terminations == 0)
        #expect(capture.phase == .finishing)

        h.sleeper.release(LiveTestTiming.exitGrace)
        try await ended(capture)

        #expect(process.terminations == 1)
        #expect(capture.phase == .ended(.finished))
        #expect(h.api.count(.finish) == 1)
    }

    @Test func endWhileTheNetworkIsDownKeepsSendingAndFinishesWhenItIsBack() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        process.onInterrupt { process in
            _ = try? process.finishPart(1)
            process.exit(0)
        }
        h.api.fail(.create, with: FakeLiveAPI.offline, FakeLiveAPI.offline)
        h.api.fail(.finish, with: FakeLiveAPI.offline, FakeLiveAPI.serverError(502, code: "SERVER_UNAVAILABLE", title: "Server unavailable", retryable: true))

        capture.end()
        try await ended(capture)

        #expect(capture.phase == .ended(.finished))
        #expect(h.api.parts.keys.sorted() == [0, 1])
        #expect(h.api.count(.finish) == 3)
        #expect(capture.waitingNote == nil)
    }

    @Test func endWhileTheStreamIsAwayDoesNotStartFFmpegAgain() async throws {
        let sleeper = LiveTestSleeper()
        sleeper.hold(LiveTestTiming.reconnect(1))
        let h = try LiveCaptureHarness(sleeper: sleeper)
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.exit(1)
        try await waitUntil("the pause before reconnecting") { sleeper.waitingCount(LiveTestTiming.reconnect(1)) == 1 }
        #expect(capture.phase == .reconnecting)

        capture.end()
        try await ended(capture)

        #expect(capture.phase == .ended(.finished))
        #expect(h.launcher.processes.count == 1)
        #expect(h.api.calls == [.start, .finish])
    }

    // MARK: - The game stops taking film

    @Test func liveEndedOnAPartStopsFFmpegAndKeepsTheUnsentParts() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        try process.finishPart(0)
        try await waitUntil("part 0 on the server") { capture.partsSent == 1 }
        process.onInterrupt { process in
            _ = try? process.finishPart(3)
            process.exit(255)
        }

        // Ended from another device: the next part's session answers 409 LIVE_ENDED.
        h.api.stopTakingFilm(.ended, reason: .finished)
        try process.finishPart(1)
        try process.finishPart(2)
        try await ended(capture)

        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(process.interrupts == 1)
        #expect(h.launcher.processes.count == 1)
        // Parts 1 and 2 and the one ffmpeg closed on the way out stay on this Mac.
        #expect(capture.partsWaiting == 3 && capture.partsSent == 1)
        #expect(h.files == ["part-00001.mp4", "part-00002.mp4", "part-00003.mp4", "parts-0.csv"])
        #expect(h.api.parts.keys.sorted() == [0])
        #expect(h.api.count(.finish) == 0)  // it is over already; nothing to tell the server
        #expect(capture.serverEndReason == .finished)
        #expect(!h.keepAwake.isAwake)
    }

    @Test func liveEndedOnCompleteCountsTheSame() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.onInterrupt { $0.exit(255) }
        h.api.fail(.complete, with: FakeLiveAPI.liveEnded)

        try process.finishPart(0)
        try await ended(capture)

        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(capture.partsWaiting == 1)
        #expect(h.files.contains("part-00000.mp4"))
    }

    @Test func aGameThatEndsElsewhereStopsTheCaptureAtTheNextStateCheckNotAtTheNextPart() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.onInterrupt { $0.exit(255) }
        try process.beginPart(0)
        try await waitUntil("capturing") { capture.phase == .capturing }
        try await waitUntil("the first state check to be due") { h.sleeper.waitingCount(LiveTestTiming.firstStatusCheck) == 1 }

        // The server has no GPU set up: the live job failed a second after the start.
        let noGPU = ErrorInfo(
            code: ErrorCode.modalNotConfigured, title: "GPU service not set up",
            message: "Modal (the GPU service) is not configured, so film cannot be analysed.", hint: "Ask IT to set it up.")
        h.api.stopTakingFilm(.ended, reason: .failed, error: noGPU)
        h.sleeper.release(LiveTestTiming.firstStatusCheck)
        try await ended(capture)

        // No part was finished, let alone refused: the state check alone stopped it.
        #expect(h.api.calls == [.start, .status])
        #expect(process.interrupts == 1)
        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(capture.serverEndReason == .failed)
        #expect(capture.serverError == noGPU)
        #expect(h.statuses.last?.game.live?.state == .ended)
    }

    @Test func aGameBeingFinishedFromAnotherDeviceStopsTheCaptureToo() async throws {
        let sleeper = LiveTestSleeper(holding: [LiveTestTiming.exitGrace, LiveTestTiming.statusCheck])
        let h = try LiveCaptureHarness(sleeper: sleeper)
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.onInterrupt { $0.exit(255) }
        try await waitUntil("the second state check to be due") { sleeper.waitingCount(LiveTestTiming.statusCheck) == 1 }
        #expect(h.api.calls == [.start, .status])  // the first check found it capturing
        #expect(capture.isActive)

        // Someone pressed End on the web page.
        h.api.stopTakingFilm(.finishing, reason: .finished)
        sleeper.release(LiveTestTiming.statusCheck, keepHolding: true)
        try await ended(capture)

        #expect(capture.phase == .ended(.noLongerTakesFilm))
        #expect(process.interrupts == 1)
        #expect(capture.serverEndReason == .finished && capture.serverError == nil)
        #expect(h.api.count(.finish) == 0)
    }

    @Test func theStateIsNotWatchedOnceThisMacIsEndingTheGame() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.onInterrupt { $0.exit(255) }
        try await waitUntil("the first state check to be due") { h.sleeper.waitingCount(LiveTestTiming.firstStatusCheck) == 1 }

        capture.end()
        try await ended(capture)

        // `finishing` is what this Mac asked for.
        #expect(capture.phase == .ended(.finished))
        #expect(h.api.calls == [.start, .finish])
    }

    // MARK: - Quitting, and parts left from before

    @Test func suspendStopsFFmpegAndKeepsThePartsAndTheGame() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        let (capture, process) = try await started(h)
        process.onInterrupt { process in
            _ = try? process.finishPart(0)
            process.exit(255)
        }
        h.api.fail(.create, with: FakeLiveAPI.offline)
        h.sleeper.hold(.seconds(1))

        await capture.suspend()

        #expect(capture.phase == .ended(.stopped))
        #expect(process.interrupts == 1)
        #expect(h.api.count(.finish) == 0)  // the game stays live
        #expect(h.files.contains("part-00000.mp4") && h.files.contains("parts-0.csv"))
        #expect(!h.keepAwake.isAwake)
        // A second end or suspend changes nothing.
        capture.end()
        await capture.suspend()
        #expect(capture.phase == .ended(.stopped))
    }

    @Test func partsLeftByAnEarlierRunAreSentFirst() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        try h.folder.create()
        let earlier = FakeLiveProcess(
            arguments: ["-segment_list", h.folder.fileURL("parts-0.csv").path(percentEncoded: false)], directory: h.folder.url)
        let zero = try earlier.finishPart(0)
        let one = try earlier.finishPart(1)
        try earlier.beginPart(2)  // the app was quit in the middle of part 2

        let (capture, process) = try await started(h)
        try await waitUntil("the leftovers on the server") { capture.partsSent == 2 }

        #expect(h.api.parts == [0: zero, 1: one])
        #expect(process.startNumber == 2)  // the unfinished part is recorded again under its number
        #expect(process.listFile.lastPathComponent == "parts-1.csv")
        try process.finishPart(2)
        try await waitUntil("the new part on the server") { capture.partsSent == 3 }
        #expect(h.api.calls.filter { FakeLiveAPI.step(of: $0) == .create } == [.create(index: 0), .create(index: 1), .create(index: 2)])
        await capture.suspend()
    }

    @Test func sendOnlySendsWhatIsLeftWithoutFFmpegAndLeavesTheGameLive() async throws {
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        try h.folder.create()
        let earlier = FakeLiveProcess(
            arguments: ["-segment_list", h.folder.fileURL("parts-0.csv").path(percentEncoded: false)], directory: h.folder.url)
        try earlier.finishPart(4)
        try earlier.finishPart(5)
        let capture = try h.capture(.sendOnly)

        try await capture.start()
        try await ended(capture)

        #expect(h.launcher.processes.isEmpty)
        #expect(h.api.parts.keys.sorted() == [4, 5])
        #expect(capture.phase == .ended(.stopped))
        #expect(capture.partsSent == 2)
        #expect(h.api.count(.finish) == 0)
        #expect(h.api.liveState == .capturing)
    }
}
#endif
