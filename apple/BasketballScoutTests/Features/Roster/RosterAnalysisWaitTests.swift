import Foundation
import Testing
@testable import BasketballScout

/// A full analysis running while the roster page is open (05 §7.8–§7.9; 09 D1 #6, R38): the assignments are
/// locked, the job is followed, and when it ends the tracks are read again, renumbered ones dropping the
/// unsaved choices, with the web's notices.
@MainActor
struct RosterAnalysisWaitTests {
    private let gamePath = RosterTestHarness.gamePath
    private static let analysisJob = "j_9a4c66f1f8cd"

    /// The ready game, one unsaved choice (track 14: Not a player), then a refetch that finds a full
    /// analysis running (`j_9a4c66f1f8cd`).
    private func waitingPage() async throws -> RosterTestHarness {
        let h = try await RosterTestHarness()
        await h.loadReadyGame()
        h.model.choose(.notAPlayer, for: 14)
        h.server.on("GET", gamePath, .fixture("game_processing.json"))
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", .fixture("job_running_before_cancel.json"))
        await h.model.refresh()
        return h
    }

    @Test func aRunningFullAnalysisLocksTheAssignments() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        #expect(model.analyzing?.id == Self.analysisJob)
        #expect(model.pollKey.jobID == Self.analysisJob)
        #expect(model.isLocked)
        #expect(!model.canSaveTracks)
        #expect(!model.canRerun)
        #expect(model.trackSectionNotices == [RosterText.analysisInProgress])
        #expect(model.tracks.pending[14] == .notAPlayer)
        model.choose(.notAPlayer, for: 3)
        #expect(model.tracks.pending[3] == nil)
        // The rosters stay editable.
        let row = model.addRow(.scouted)
        model.setField(.jersey, row: row, side: .scouted, to: "7")
        #expect(model.editors.scouted.isDirty)
    }

    @Test func whenItFinishesTheRenumberedTracksReplaceTheChoices() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        var finished = try Fixture.decode(Job.self, "job_running_before_cancel.json")
        finished.status = .succeeded
        finished.stage = .done
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", try RosterTestHarness.reply(finished))
        h.server.on("GET", gamePath, .fixture("game_ready.json"))
        var fresh = try RosterTestHarness.tracks()
        fresh.assignments = fresh.assignments.map { assignment in
            var renumbered = assignment
            renumbered.trackID += 100
            return renumbered
        }
        fresh.overrides = []
        h.server.on("GET", "\(gamePath)/tracks", try RosterTestHarness.reply(fresh))

        await model.followAnalysis()

        #expect(model.analyzing == nil)
        #expect(!model.isLocked)
        #expect(model.tracks.pending.isEmpty)
        #expect(model.tracks.overrides.isEmpty)
        #expect(model.tracks.assignments.first?.trackID == 103)
        #expect(model.tracksNotice == RosterNotice(
            tone: .info, title: "Film analysis finished",
            message: "It numbered the players' tracks again, so your unsaved track choices were dropped. Make them again in the new table."))
    }

    @Test func aCancelledAnalysisKeepsTheTableAndTheChoices() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", .fixture("job_cancelled_2_cancelled_done.json"))
        h.server.on("GET", gamePath, .fixture("game_ready.json"))

        await model.followAnalysis()

        #expect(model.analyzing == nil)
        #expect(model.tracks.pending[14] == .notAPlayer)
        #expect(model.tracksNotice == nil)
        #expect(model.trackSectionNotices.isEmpty)
        #expect(model.canSaveTracks)
    }

    @Test func anotherFullAnalysisStartedMeanwhileKeepsTheTableLocked() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", .fixture("job_cancelled_2_cancelled_done.json"))
        let game = try SessionFixtures.game("game_processing.json") { $0.latestJobID = "j_6d97c2b25cbf" }
        h.server.on("GET", gamePath, try RosterTestHarness.reply(game))
        h.server.on("GET", "/api/jobs/j_6d97c2b25cbf", .fixture("job_late_cancel_1_running_analyzing.json"))

        await model.followAnalysis()

        #expect(model.analyzing?.id == "j_6d97c2b25cbf")
        #expect(model.isLocked)
        #expect(model.tracks.pending[14] == .notAPlayer)
        #expect(model.trackSectionNotices == [RosterText.analysisInProgress])
    }

    @Test func pollingThatGivesUpSaysSoUntilReloaded() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", .fixture("err_404_job_unknown.json", status: 404))

        await model.followAnalysis()

        #expect(model.stoppedChecking)
        #expect(model.isLocked)
        #expect(model.trackSectionNotices.contains(RosterText.stoppedChecking))
        let attempt = model.pollAttempt
        await model.reloadPage()
        #expect(!model.stoppedChecking)
        #expect(model.pollAttempt == attempt + 1)
        #expect(model.isLocked)
    }

    @Test func aGameLeftWithoutAnAnalysisShowsNoTable() async throws {
        let h = try await waitingPage()
        defer { h.cleanUp() }
        let model = h.model
        h.server.on("GET", "/api/jobs/\(Self.analysisJob)", .fixture("job_failed_1_failed_preparing.json"))
        let game = try SessionFixtures.game("game_ready.json") { game in
            game.hasAnalysis = false
            game.status = .failed
        }
        h.server.on("GET", gamePath, try RosterTestHarness.reply(game))

        await model.followAnalysis()

        #expect(model.analyzing == nil)
        #expect(!model.tracks.isShown)
        #expect(model.sections == [.roster(.scouted), .roster(.other)])
        #expect(model.visibleSection == .roster(.scouted))
        let notice = try #require(model.pageTrackNotices.first)
        #expect(notice.title == "Film analysis finished without results")
        #expect(notice.message == "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped.")
        #expect(notice.action == .openGamePage)
    }

    @Test func aRefetchThatFindsRenumberedTracksSaysSo() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.model.choose(.notAPlayer, for: 14)
        var fresh = try RosterTestHarness.tracks()
        fresh.assignments[0].frames = 5999
        h.server.on("GET", "\(gamePath)/tracks", try RosterTestHarness.reply(fresh))

        await h.model.refresh()

        #expect(h.model.tracks.pending.isEmpty)
        #expect(h.model.tracksNotice == RosterText.numberedAgain(tableShown: true))
        #expect(!h.model.isLocked)
    }

    @Test func tracksThatCannotBeReadShowTheCardWithTheError() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.serveReadyGame()
        h.server.on("GET", "\(gamePath)/tracks", RosterTestHarness.error(
            500, code: "ANALYSIS_FAILED", title: "Analysis failed", message: "The saved analysis could not be read."))
        await h.model.refresh()
        #expect(h.model.tracks.isShown)
        #expect(h.model.tracks.assignments.isEmpty)
        #expect(h.model.tracksError?.message == "The saved analysis could not be read.")
        #expect(h.model.sections.contains(.tracks))
    }

    @Test func analysisNotReadyMeansNoTable() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.serveReadyGame()
        h.server.on("GET", "\(gamePath)/tracks", .fixture("err_409_analysis_not_ready.json", status: 409))
        await h.model.refresh()
        #expect(!h.model.tracks.isShown)
        #expect(h.model.tracksError == nil)
    }
}
