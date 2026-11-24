import Foundation
import Testing
@testable import BasketballScout

/// The games list's compact System status row (07 §3.8; index.js `healthWarnings`): shown only when the
/// server reports something the web's panel warns about, naming the most serious warning.
struct GamesSystemStatusSummaryTests {
    private func health(_ fixture: String, change: (inout HealthStatus) -> Void = { _ in }) throws -> HealthStatus {
        var health = try Fixture.decode(HealthStatus.self, fixture)
        change(&health)
        return health
    }

    @Test func nothingToShowWithoutAnAnswerOrAWarning() throws {
        #expect(GamesSystemStatusSummary(health: nil) == nil)
        let fine = try health("health.json") {
            $0.processor = "modal"
            $0.modalConfigured = true
            $0.claudeConfigured = true
            $0.ffmpegAvailable = true
        }
        #expect(GamesSystemStatusSummary(health: fine) == nil)
    }

    @Test func aDemoServerWithoutClaudeOrFfmpeg() throws {
        // health.json: demo mode (info), Claude not configured (warning), no ffmpeg (warning).
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json")))
        #expect(summary.tone == .warning)
        #expect(!summary.needsAttention)
        #expect(summary.headline == "Claude is not configured, so scouting reports can't be written.")
        #expect(summary.otherCount == 2)
        #expect(summary.moreText == "2 more notices")
    }

    @Test func aWorkerThatStoppedAnsweringNeedsAttention() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health_degraded.json")))
        #expect(summary.tone == .danger)
        #expect(summary.needsAttention)
        #expect(summary.headline == "The background worker was last seen 2 min ago - it may have stopped.")
        #expect(summary.otherCount == 3)
        #expect(summary.spokenText
            == "System status. Needs attention. The background worker was last seen 2 min ago - it may have stopped. 3 more notices")
    }

    @Test func aWorkerNeverSeenComesFirst() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json") {
            $0.status = .degraded
            $0.workerLastSeenS = nil
        }))
        #expect(summary.headline == "The background worker is not running - start basketball-scout-worker.")
        #expect(summary.tone == .danger)
    }

    @Test func amongEquallySeriousWarningsTheWebsOrderWins() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json") {
            $0.status = .degraded
            $0.queueOK = false
            $0.queueBackend = "redis"
            $0.processor = "modal"
        }))
        // Errors: the job queue, then Modal; then the two warnings.
        #expect(summary.headline == "The job queue (redis) is not reachable.")
        #expect(summary.otherCount == 3)
    }

    @Test func demoModeAloneIsInformation() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json") {
            $0.claudeConfigured = true
            $0.ffmpegAvailable = true
        }))
        #expect(summary.tone == .info)
        #expect(summary.headline == "Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.")
        #expect(summary.otherCount == 0)
        #expect(summary.moreText == nil)
        #expect(summary.spokenText
            == "System status. Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.")
    }

    @Test func oneOtherNoticeIsCountedInTheSingular() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json") { $0.ffmpegAvailable = true }))
        #expect(summary.headline == "Claude is not configured, so scouting reports can't be written.")
        #expect(summary.moreText == "1 more notice")
    }

    @Test func aStatusThisAppDoesNotKnowStillNeedsAttention() throws {
        let summary = try #require(GamesSystemStatusSummary(health: try health("health.json") {
            $0.status = .unknown("maintenance")
            $0.processor = "local"
            $0.claudeConfigured = true
            $0.ffmpegAvailable = true
        }))
        #expect(summary.tone == .danger)
        #expect(summary.needsAttention)
        #expect(summary.headline == GamesSystemStatusSummary.unexplainedProblem)
        #expect(summary.otherCount == 0)
    }

    @Test func severityOrdersErrorsWarningsInformation() {
        #expect(GamesSystemStatusSummary.severity(.danger) > GamesSystemStatusSummary.severity(.warning))
        #expect(GamesSystemStatusSummary.severity(.warning) > GamesSystemStatusSummary.severity(.info))
        #expect(GamesSystemStatusSummary.severity(.info) > GamesSystemStatusSummary.severity(.neutral))
        #expect(GamesSystemStatusSummary.mostSerious([]) == nil)
    }
}
