import Foundation
import Testing
@testable import BasketballScout

/// The job panel's states (03 §7.5; jobpanel.js) from the captured jobs.
@MainActor
struct GameDetailJobPanelStateTests {
    /// 200 s after the fixtures' `started_at` of the first ANALYZE (2026-11-11T20:01:04.134992Z).
    private let now = ScoutTimestamp.date(from: "2026-11-11T20:04:24.134992Z")!

    private func state(_ job: Job?, tracking: Bool = true, cancelling: String? = nil) -> GameDetailJobPanelState {
        GameDetailJobPanelState(job: job, gameHasTracking: tracking, cancellingJobID: cancelling, now: now)
    }

    private func active(_ state: GameDetailJobPanelState) throws -> GameDetailJobPanelState.Active {
        guard case .active(let active) = state else {
            Issue.record("expected an active panel, got \(state)")
            throw PanelMismatch()
        }
        return active
    }

    private func finished(_ state: GameDetailJobPanelState) throws -> GameDetailJobPanelState.Finished {
        switch state {
        case .cancelled(let finished), .failed(let finished): return finished
        default:
            Issue.record("expected a finished panel, got \(state)")
            throw PanelMismatch()
        }
    }

    private struct PanelMismatch: Error {}

    // MARK: - Active jobs

    @Test func aRunningAnalyzeShowsStageProgressAndDetails() throws {
        let job = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")

        let panel = try active(state(job))

        #expect(panel.title == "Film analysis in progress")
        #expect(panel.stage == "Analyzing on the GPU (5%)")
        #expect(panel.fraction == 0.05)
        #expect(panel.details == "5% overall \u{00B7} Demo mode: simulating GPU processing (0%) \u{00B7} running for 3 min 20 s")
        #expect(panel.cancelTitle == "Cancel")
        #expect(panel.canCancel)
        #expect(!panel.isQueued)
        #expect(panel.job == job)
    }

    @Test func aQueuedJobHasAnIndeterminateBarAndNoElapsedTime() throws {
        let job = try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json")

        let panel = try active(state(job))

        #expect(panel.title == "Re-analysis in progress")
        #expect(panel.stage == "Waiting for the background worker")
        #expect(panel.fraction == nil)
        #expect(panel.details == "0% overall \u{00B7} Waiting for a worker")
        #expect(panel.isQueued)
    }

    @Test func afterACancelRequestTheMessageIsHidden() throws {
        // 09 D1 #10: the server's "Cancelling..." would repeat the stage line and the button.
        let job = try Fixture.decode(Job.self, "job_cancel_running.json")
        let started = try #require(job.startedAt)

        let panel = try active(GameDetailJobPanelState(
            job: job, gameHasTracking: true, cancellingJobID: nil, now: started.addingTimeInterval(45)))

        #expect(panel.stage == "Cancelling\u{2026}")
        #expect(panel.cancelTitle == "Cancelling\u{2026}")
        #expect(!panel.canCancel)
        #expect(panel.details == "27% overall \u{00B7} running for 45 s")
    }

    @Test func aCancelThatCameTooLateKeepsTheStage() throws {
        let job = try Fixture.decode(Job.self, "job_cancel_too_late.json")

        let panel = try active(state(job))

        #expect(panel.stage == "Building box score")
        #expect(panel.cancelTitle == "Cancel requested")
        #expect(!panel.canCancel)
        #expect(!panel.details.contains("Cancel requested: too late"))
    }

    @Test func whileTheCancelIsSentTheButtonSaysWhatItWillBecome() throws {
        let stoppable = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let tooLate = try Fixture.decode(Job.self, "job_analyze_3_running_analyzing.json")

        let sending = try active(state(stoppable, cancelling: stoppable.id))
        let sendingLate = try active(state(tooLate, cancelling: tooLate.id))
        let other = try active(state(stoppable, cancelling: "j_000000000000"))

        #expect(sending.cancelTitle == "Cancelling\u{2026}")
        #expect(!sending.canCancel)
        #expect(sendingLate.cancelTitle == "Cancel requested")
        #expect(!sendingLate.canCancel)
        #expect(other.cancelTitle == "Cancel")
        #expect(other.canCancel)
    }

    @Test func theElapsedTimeNeverGoesNegative() throws {
        // 09 R35: a device clock behind the server's.
        let job = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let started = try #require(job.startedAt)

        let panel = try active(GameDetailJobPanelState(
            job: job, gameHasTracking: true, cancellingJobID: nil, now: started.addingTimeInterval(-30)))

        #expect(panel.details.hasSuffix("running for 0 s"))
    }

    // MARK: - Finished jobs

    @Test func noJobOrASucceededJobWithoutWarningsHidesThePanel() throws {
        #expect(state(nil) == .hidden)
        #expect(state(try Fixture.decode(Job.self, "job_analyze_4_succeeded_done.json")) == .hidden)
    }

    @Test func warningsAfterSuccessAreListed() throws {
        let job = try Fixture.decode(Job.self, "job_late_cancel_2_succeeded_done.json")

        #expect(state(job) == .finishedWithWarnings(
            title: "Film analysis finished with warnings",
            warnings: ["Cancelled after the new GPU results were in place: the analysis was finished."]))
    }

    @Test func aCancelledFullRunOffersStartAgainAndAsksFirst() throws {
        let job = try Fixture.decode(Job.self, "job_cancelled_2_cancelled_done.json")  // ANALYZE

        guard case .cancelled(let panel) = state(job) else {
            Issue.record("expected the cancelled panel")
            return
        }
        #expect(panel.notice?.title == "Film analysis was cancelled")
        #expect(panel.notice?.message == "Start it again whenever you are ready.")
        #expect(panel.action == .startAgain)
        #expect(panel.action?.title == "Start again")
        #expect(panel.needsConfirmation)
        // Without GPU results there is nothing a new GPU run would clear: no question (03 §7.5).
        #expect(try finished(state(job, tracking: false)).needsConfirmation == false)
    }

    @Test func aCancelledReanalysisStartsAgainWithoutAsking() throws {
        let job = try Fixture.decode(Job.self, "job_cancel_queued.json")  // REANALYZE

        let panel = try finished(state(job))

        #expect(panel.notice?.title == "Re-analysis was cancelled")
        #expect(panel.action == .startAgain)
        #expect(!panel.needsConfirmation)
    }

    @Test func aFailureThatRetryingCannotFixHasNoButton() throws {
        let job = try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")  // VIDEO_MISSING, not retryable

        guard case .failed(let panel) = state(job, tracking: false) else {
            Issue.record("expected the failed panel")
            return
        }
        #expect(panel.error?.title == "No video")
        #expect(panel.error?.message == "This game has no film yet.")
        #expect(panel.error?.hint == "Upload an MP4 or provide a video URL first.")
        #expect(panel.action == nil)
    }

    @Test func anAnalyzeThatFailedPastTheGPUOffersRerunAnalysis() throws {
        // Shown even when not retryable; the server retries it as a REANALYZE, so nothing to confirm.
        let job = try SessionFixtures.job("job_analyze_3_running_analyzing.json") {
            $0.status = .failed
            $0.error = ErrorInfo(code: ErrorCode.analysisFailed, title: "Analysis failed", message: "The box score could not be built.")
        }

        let panel = try finished(state(job))

        #expect(panel.action == .rerunAnalysis)
        #expect(panel.action?.title == "Re-run analysis")
        #expect(!panel.needsConfirmation)
    }

    @Test func aJobTheQueueRefusedOffersRetryAndAsksFirst() throws {
        // 09 B4 / C4: stage "done", message = error.message, retryable.
        let job = try SessionFixtures.job("job_create_analyze_full.json") {
            $0.status = .failed
            $0.stage = .done
            $0.message = "The job queue (Redis) could not be reached."
            $0.error = ErrorInfo(
                code: ErrorCode.queueUnavailable, title: "Job queue unavailable",
                message: "The job queue (Redis) could not be reached.",
                hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.", retryable: true)
        }

        let panel = try finished(state(job))

        #expect(panel.action == .retry)
        #expect(panel.needsConfirmation)
        #expect(panel.error?.title == "Job queue unavailable")
    }

    @Test func aFailureWithoutAnErrorUsesTheKindAndMessage() throws {
        let job = try SessionFixtures.job("job_reanalyze_3_succeeded_done.json") {
            $0.status = .failed
            $0.stage = .analyzing
            $0.message = ""
        }

        let panel = try finished(state(job))

        #expect(panel.error?.title == "Re-analysis failed")
        #expect(panel.error?.message == "The job stopped with an error.")
        #expect(panel.action == .retry)  // a missing error counts as retryable
    }

    // MARK: - Keys

    @Test func aPanelIsKeyedByItsJobAndFinalStatus() throws {
        let queued = try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json")
        let running = try Fixture.decode(Job.self, "job_reanalyze_2_running_analyzing.json")
        let done = try Fixture.decode(Job.self, "job_reanalyze_3_succeeded_done.json")

        #expect(GameDetailJobPanelState.key(for: queued) == GameDetailJobPanelState.key(for: running))
        #expect(GameDetailJobPanelState.key(for: running) != GameDetailJobPanelState.key(for: done))
        #expect(GameDetailJobPanelState.key(for: done) == "j_a337003622c0:succeeded")
        #expect(state(running).job == running)
        #expect(state(nil).job == nil)
    }

    /// The active panel's last line, in the app's words (the web: "You can close this page; …").
    @Test func theFooterSaysProcessingContinuesOnTheServer() {
        #expect(GameDetailText.jobPanelFooter == "You can leave this screen or close the app; processing continues on the server.")
    }
}
