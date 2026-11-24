import Foundation
import Testing
@testable import BasketballScout

/// Live games in the models (docs/LIVE.md "Data"): `Game.live` with and without the key, the parts, the
/// LIVE job, a part's upload session, `LIVE_ENDED`, and what the app works out from them. The fixtures are
/// answers of a real server driven through one live game.
nonisolated struct LiveModelTests {
    // MARK: - Decoding

    @Test func aGameFromAServerWithoutLiveGamesHasNoLiveRecord() throws {
        // The 08 fixtures come from a server older than live games: no `live` key at all.
        let raw = try #require(try Fixture.jsonObject("game_ready.json") as? [String: Any])
        #expect(raw["live"] == nil)
        let game = try Fixture.decode(Game.self, "game_ready.json")
        #expect(game.live == nil)
        #expect(!game.isLive)
        #expect(game.liveBadge == nil)
        #expect(game.offersFilmAndAnalysisActions)
    }

    @Test func aNormalGameOnANewServerHasANullLiveRecord() throws {
        let raw = try #require(try Fixture.jsonObject("live_game_create.json") as? [String: Any])
        #expect(raw["live"] is NSNull)
        let game = try Fixture.decode(Game.self, "live_game_create.json")
        #expect(game.live == nil)
        #expect(game.canGoLive)
    }

    @Test func aLiveGameDecodesItsLiveRecord() throws {
        let game = try Fixture.decode(Game.self, "live_game_capturing.json")
        let live = try #require(game.live)
        #expect(live.state == .capturing)
        #expect(live.segmentSeconds == 120)
        #expect(live.segmentsReceived == 2)
        #expect(live.segmentsAnalysed == 2)
        #expect(live.segmentsFailed == 0)
        #expect(live.segmentsEmpty == 0)
        #expect(live.receivedS == 240.033)
        #expect(live.analysedS == 240.033)
        #expect(live.analysisVersion >= 1)
        #expect(live.startedAt != nil && live.lastSegmentAt != nil)
        #expect(live.endedAt == nil && live.endReason == nil)
        #expect(game.status == .ready)
        #expect(game.hasAnalysis && !game.hasVideo && !game.hasTracking)
        #expect(game.isLive)
    }

    @Test func liveInfoWithoutSegmentsEmptyCountsNone() throws {
        // A server from before parts without play were counted apart.
        let json = Data(#"""
        {"state":"capturing","segment_seconds":120,"segments_received":7,"segments_analysed":5,"segments_failed":1,
         "received_s":842.1,"analysed_s":601.3,"analysis_version":5,"started_at":"2026-12-04T00:31:10Z",
         "last_segment_at":"2026-12-04T00:45:22Z","ended_at":null,"end_reason":null}
        """#.utf8)
        let live = try ScoutJSON.decode(LiveInfo.self, from: json)
        #expect(live.segmentsEmpty == 0)
        #expect(live.segmentsSettled == 5)
        #expect(live.startedAt == ScoutTimestamp.date(from: "2026-12-04T00:31:10Z"))
    }

    @Test func unknownLiveValuesDoNotFailTheStatus() throws {
        var object = try #require(try Fixture.jsonObject("live_status_capturing.json") as? [String: Any])
        var game = try #require(object["game"] as? [String: Any])
        var live = try #require(game["live"] as? [String: Any])
        live["state"] = "paused"
        live["end_reason"] = "power_cut"
        live["segments_empty"] = 3
        game["live"] = live
        object["game"] = game
        var segments = try #require(object["segments"] as? [[String: Any]])
        segments[0]["status"] = "empty"
        segments[1]["status"] = "quarantined"
        object["segments"] = segments
        let status = try ScoutJSON.decode(LiveStatus.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(status.game.live?.state == .unknown("paused"))
        #expect(status.game.live?.endReason == .unknown("power_cut"))
        #expect(status.game.live?.segmentsEmpty == 3)
        #expect(status.segments.map(\.status) == [.empty, .unknown("quarantined")])
        // Anything but `ended` is live.
        #expect(status.game.isLive)
    }

    @Test func liveStatusCarriesTheGameThePartsAndTheJob() throws {
        let started = try Fixture.decode(LiveStatus.self, "live_start.json")
        #expect(started.segments.isEmpty)
        #expect(started.nextSegmentIndex == 0)
        #expect(started.job?.kind == .live)
        #expect(started.job?.status == .queued)
        #expect(started.game.status == .queued)
        #expect(started.game.latestJobID == started.job?.id)

        let capturing = try Fixture.decode(LiveStatus.self, "live_status_capturing.json")
        #expect(capturing.segments.map(\.index) == [0, 1])
        #expect(capturing.segments.map(\.status) == [.done, .done])
        #expect(capturing.segments[0].filename == "part-00000.mp4")
        #expect(capturing.segments[0].durationS == 120.133333)
        #expect(capturing.segments[0].size == 4096)
        #expect(capturing.segments[0].gameID == capturing.game.id)
        #expect(capturing.segments[0].error == nil)
        #expect(capturing.nextSegmentIndex == 2)
        #expect(capturing.job?.stage == .gpuProcessing)

        let finishing = try Fixture.decode(LiveStatus.self, "live_finish.json")
        #expect(finishing.game.live?.state == .finishing)
        #expect(finishing.game.live?.endReason == .finished)
        #expect(finishing.game.isLive)

        let ended = try Fixture.decode(LiveStatus.self, "live_status_ended.json")
        #expect(ended.game.live?.state == .ended)
        #expect(ended.game.live?.endedAt != nil)
        #expect(!ended.game.isLive)
        #expect(ended.game.hasTracking)
        #expect(ended.job?.status == .succeeded)

        let cancelled = try Fixture.decode(LiveStatus.self, "live_status_cancelled.json")
        #expect(cancelled.game.live?.endReason == .cancelled)
        #expect(cancelled.game.live?.endedWithoutFilm == true)
        #expect(cancelled.game.status == .draft)
        #expect(cancelled.job?.status == .cancelled)
    }

    @Test func aLivePartsUploadSessionSaysWhichPartItCarries() throws {
        let created = try Fixture.decode(UploadSession.self, "live_segment_create.json")
        #expect(created.liveSegment == 0)
        #expect(created.liveDurationS == 120.133333)
        #expect(created.status == .open && created.received == 0)

        let resumed = try Fixture.decode(UploadSession.self, "live_segment_create_resume.json")
        #expect(resumed.id == created.id)
        #expect(resumed.status == .open && resumed.received == 1500)

        let existing = try Fixture.decode(UploadSession.self, "live_segment_create_existing.json")
        #expect(existing.status == .complete && existing.isFullyReceived)

        // A film upload of an older server has neither key.
        let film = try Fixture.decode(UploadSession.self, "upload_create.json")
        #expect(film.liveSegment == nil && film.liveDurationS == nil)
    }

    @Test func completeOnALivePartAnswersWithTheLiveGame() throws {
        let result = try Fixture.decode(FilmResult.self, "live_segment_complete.json")
        #expect(result.game.live?.segmentsReceived == 1)
        #expect(result.game.live?.receivedS == 120.133)
        #expect(result.job?.kind == .live)
    }

    @Test func liveEndedIsAnErrorCodeOfItsOwn() throws {
        let envelope = try Fixture.decode(ErrorEnvelope.self, "err_409_live_ended_segment.json")
        #expect(envelope.error.code == ErrorCode.liveEnded)
        #expect(envelope.error.title == "The live game has ended")
        #expect(envelope.error.retryable == false)
        #expect(ErrorCode.serverCodes.contains(ErrorCode.liveEnded))
        #expect(ErrorCode.serverCodes.count == 44)
        let again = try Fixture.decode(ErrorEnvelope.self, "err_409_live_start_ended.json")
        #expect(again.error.code == ErrorCode.liveEnded)
        // Another analysis or new film during a live game is a plain conflict.
        #expect(try Fixture.decode(ErrorEnvelope.self, "err_409_job_while_live.json").error.code == ErrorCode.conflict)
        #expect(try Fixture.decode(ErrorEnvelope.self, "err_409_upload_while_live.json").error.code == ErrorCode.conflict)
    }

    @Test func requestBodiesUseTheServersNames() throws {
        let part = LiveSegmentInit(index: 7, durationS: 120.1, size: 48_211_234, filename: "part-00007.mp4")
        #expect(String(decoding: try ScoutJSON.encode(part), as: UTF8.self)
            == #"{"duration_s":120.1,"filename":"part-00007.mp4","index":7,"size":48211234}"#)
        #expect(String(decoding: try ScoutJSON.encode(LiveStart(segmentSeconds: 120)), as: UTF8.self) == #"{"segment_seconds":120}"#)
    }

    // MARK: - What the app works out from a live game

    @Test func aLiveGameIsLiveUntilItHasEnded() throws {
        #expect(try Fixture.decode(Game.self, "live_game_waiting.json").isLive)
        #expect(try Fixture.decode(Game.self, "live_game_capturing.json").isLive)
        #expect(try Fixture.decode(LiveStatus.self, "live_finish.json").game.isLive)
        #expect(try !Fixture.decode(Game.self, "live_game_ended.json").isLive)
    }

    @Test func theLiveBadgeReplacesTheStatusBadge() throws {
        let live = try Fixture.decode(Game.self, "live_game_capturing.json")
        #expect(live.statusBadge == BadgeLabel("Live", tone: .danger, systemImage: "dot.radiowaves.left.and.right"))
        let ended = try Fixture.decode(Game.self, "live_game_ended.json")
        #expect(ended.statusBadge == BadgeLabel("Ready", tone: .success))
    }

    @Test func aLiveGameOffersNoFilmChangeAndNoOtherAnalysis() throws {
        let live = try Fixture.decode(Game.self, "live_game_capturing.json")
        #expect(!live.offersFilmAndAnalysisActions)
        #expect(!live.canRerun)
        #expect(!live.showsFullReanalysis)
        #expect(!live.canGoLive)
        let actions = GameDetailActionState(game: live, isBusy: true, isStarting: false)
        #expect(!actions.showsFilmAndAnalysisActions)
        #expect(!actions.canRerun && !actions.showsFullReanalysis && !actions.canFullReanalysis)

        // After the end it is a normal game again (here the server could not join the film: it has the stats and
        // the GPU results, so the stats can be rebuilt and a film can be added).
        let ended = try Fixture.decode(Game.self, "live_game_ended.json")
        #expect(ended.offersFilmAndAnalysisActions)
        #expect(ended.canRerun)
        #expect(ended.filmButtonTitle == "Add film")
        #expect(!ended.canGoLive)
    }

    @Test func aGameCanGoLiveOnlyWithoutFilmAndOnce() throws {
        #expect(try Fixture.decode(Game.self, "game_get.json").canGoLive)
        #expect(try !Fixture.decode(Game.self, "game_ready.json").canGoLive)
        #expect(try !Fixture.decode(Game.self, "game_link_ready.json").canGoLive)
        #expect(try !Fixture.decode(Game.self, "live_game_waiting.json").canGoLive)
        // A live stream that ended before any film arrived can be started again (scout/live.py).
        #expect(try Fixture.decode(LiveStatus.self, "live_status_cancelled.json").game.canGoLive)
    }

    @Test func beforeTheFirstStatsThePageSaysTheyAreOnTheirWay() throws {
        let waiting = try Fixture.decode(Game.self, "live_game_waiting.json")
        #expect(!waiting.hasAnalysis && !waiting.hasFilm)
        // Not "No film yet" with "Add film".
        #expect(!waiting.showsNoFilmCard(hasAnalysis: false))
        let notice = waiting.pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: true)
        #expect(notice == .info(NoticeText(
            tone: .info, message: "The stats appear here a few minutes after the stream starts.",
            hint: "Each part of the film is analysed as it arrives.")))
        // A draft game that is not live keeps the card.
        #expect(try Fixture.decode(Game.self, "game_get.json").showsNoFilmCard(hasAnalysis: false))
    }

    @Test func duringTheGameTheFilmsPlaceSaysItComesAfterTheStream() throws {
        let live = try Fixture.decode(Game.self, "live_game_capturing.json")
        #expect(live.pendingNotice(hasAnalysis: true, latestAnalysisJob: nil, jobPanelVisible: true) == nil)
        let notice = try #require(live.filmUnavailableNotice(hasAnalysis: true))
        #expect(notice.title == "The film comes after the game")
        #expect(notice.message == "The film is put together when the stream ends. The stats below fill in during the game.")
        // Once it has ended without a film on the server, the usual notice (with "Upload the film") is back.
        let ended = try Fixture.decode(Game.self, "live_game_ended.json")
        #expect(ended.filmUnavailableNotice(hasAnalysis: true)?.title == "Film not available")
    }

    // MARK: - The LIVE job

    @Test func theLiveJobReadsAsLiveAnalysis() throws {
        let job = try Fixture.decode(Job.self, "live_job_running.json")
        #expect(job.kind == .live)
        #expect(job.panelTitle == "Live analysis in progress")
        // Its percent only says how many of the parts so far are analysed, so the stage line leaves it out.
        #expect(job.stageText == "Analysing the film as it arrives")
        #expect(job.message.hasPrefix("Live: 2 of 2 parts analysed"))
        #expect(!job.isTooLateToCancel)
        #expect(JobKind.live.isAnalysis)
        #expect([job].latestAnalysisJob?.id == job.id)

        let done = try Fixture.decode(Job.self, "live_job_succeeded.json")
        #expect(done.stageText == "Finished")
        #expect(done.finishedWithWarningsTitle == "Live analysis finished with warnings")
        #expect(done.showsPanel)  // this server had no ffmpeg to put the film together
    }

    @Test func cancellingALiveJobAsksInItsOwnWords() {
        func job(_ stage: JobStage) -> Job { Job(id: "j_1", gameID: "g_1", kind: .live, status: .running, stage: stage) }
        let early = job(.gpuProcessing).cancelQuestion
        #expect(early.title == "Stop the live analysis now?")
        #expect(early.message?.contains("End live game") == true)
        #expect(job(.queued).cancelQuestion.title == "Stop the live analysis now?")
        // At `reporting` the game is over: only the report is left, as for any analysis.
        #expect(job(.reporting).isTooLateToCancel)
        #expect(job(.reporting).cancelQuestion.title.hasPrefix("Too late to cancel"))
        #expect(job(.analyzing).cancelQuestion.title == "Stop the live analysis now?")
    }

    @Test func aCancelledOrFailedLiveJobRestartsAsAnAnalysisOfTheFilm() throws {
        let cancelled = try #require(try Fixture.decode(LiveStatus.self, "live_status_cancelled.json").job)
        #expect(cancelled.cancelledNotice.title == "Live analysis was cancelled")
        #expect(cancelled.cancelledNotice.message == "The stats so far are kept. Start again analyses the film that arrived.")
        #expect(cancelled.finishedAction == .startAgain)
        // The retry is a GPU run: with GPU results on the server it is asked about first.
        #expect(cancelled.retriesOnTheGPU)
        #expect(cancelled.retryNeedsConfirmation(gameHasTracking: true))
        #expect(!cancelled.retryNeedsConfirmation(gameHasTracking: false))

        // No film had arrived: nothing to start again (the server would answer VIDEO_MISSING).
        let empty = GameDetailJobPanelState(
            job: cancelled, gameHasTracking: false, cancellingJobID: nil, now: Date(), liveEndedWithoutFilm: true)
        guard case .cancelled(let finished) = empty else {
            Issue.record("expected the cancelled panel")
            return
        }
        #expect(finished.action == nil)
        #expect(finished.notice?.message == "No film had arrived. You can start the live stream again from Add film.")

        let withFilm = GameDetailJobPanelState(job: cancelled, gameHasTracking: false, cancellingJobID: nil, now: Date())
        guard case .cancelled(let restartable) = withFilm else {
            Issue.record("expected the cancelled panel")
            return
        }
        #expect(restartable.action == .startAgain)
    }
}
