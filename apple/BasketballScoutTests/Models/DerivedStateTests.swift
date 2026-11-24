import Foundation
import Testing
@testable import BasketballScout

/// What the web computes from the models (03 §4 "Derived states", §7.3–§7.7; 05 §7.5, §7.9; 06 §5.3, §9).
nonisolated struct DerivedStateTests {
    private func game(
        status: GameStatus = .uploaded, hasVideo: Bool = false, videoURL: String? = nil, annotated: Bool = false,
        tracking: Bool = false, error: ErrorInfo? = nil
    ) -> Game {
        Game(id: "g_1", scoutedTeam: "Test Team A", otherTeam: "Test Team B", status: status, videoURL: videoURL,
             hasVideo: hasVideo, hasAnnotatedVideo: annotated, hasTracking: tracking, error: error)
    }

    @Test func filmPlayableAndRerunKind() throws {
        // 03 §4: hasFilm = has_video || video_url; playable = has_video || has_annotated_video; rerunKind by has_tracking.
        #expect(!game().hasFilm && !game().isPlayable)
        #expect(game(hasVideo: true).hasFilm && game(hasVideo: true).isPlayable)
        #expect(game(videoURL: "https://example.com/a.mp4").hasFilm && !game(videoURL: "https://example.com/a.mp4").isPlayable)
        #expect(game(videoURL: "https://example.com/a.mp4", annotated: true).isPlayable)
        #expect(game().rerunKind == .analyze && game(tracking: true).rerunKind == .reanalyze)

        let link = try Fixture.decode(Game.self, "game_link_ready.json")
        #expect(link.hasFilm && !link.isPlayable && link.filmButtonTitle == "Replace film")
        let draft = try Fixture.decode(Game.self, "game_create.json")
        #expect(!draft.hasFilm && draft.filmButtonTitle == "Add film" && !draft.canRerun)
    }

    @Test func teamIDMapKeysStayStrings() throws {
        // 01 §1.2 / 09 R23: dict[int, TeamSide] arrives with string keys; they are kept as sent.
        var object = try #require(try Fixture.jsonObject("game_patch_team_id_map.json") as? [String: Any])
        object["team_id_map"] = ["0": "scouted", "1": "home", "x": "other"]
        let game = try ScoutJSON.decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(game.teamIDMap == ["0": .scouted, "1": .unknown("home"), "x": .other])
        #expect(game.teamIDsBySide == [0: .scouted, 1: .unknown("home")])
        let again = try #require(try JSONSerialization.jsonObject(with: ScoutJSON.encode(game)) as? [String: Any])
        #expect(again["team_id_map"] as? [String: String] == ["0": "scouted", "1": "home", "x": "other"])
    }

    @Test func headerButtons() {
        // 03 §7.4
        let ready = game(status: .ready, hasVideo: true, tracking: true)
        #expect(ready.rerunButtonTitle == "Re-run analysis" && ready.canRerun && ready.showsFullReanalysis)
        #expect(ready.rerunHelp == "Redo the stats on this server (about a minute, no GPU)")
        #expect(ready.fullReanalysisHelp == "Send the film to the GPU again")
        let busy = game(status: .processing, hasVideo: true, tracking: true)
        #expect(busy.isBusy && !busy.canRerun && busy.rerunHelp == "An analysis is already running")
        #expect(busy.fullReanalysisHelp == "An analysis is already running")
        let fresh = game(status: .uploaded, hasVideo: true)
        #expect(fresh.rerunButtonTitle == "Analyze film" && fresh.canRerun && fresh.rerunHelp == nil && !fresh.showsFullReanalysis)
        // GPU results without film (link removed?): a re-run still works.
        #expect(game(status: .uploaded, tracking: true).canRerun)
    }

    @Test func teamNames() throws {
        // game.js:59-65: analysis name, else game name, else "Scouted team"/"Opponent".
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let plain = game()
        #expect(plain.teamName(.scouted, analysis: analysis) == "Test Team A")
        #expect(plain.teamName(.other) == "Test Team B")
        let unnamed = Game(id: "g_2", scoutedTeam: "Test Team C")
        #expect(unnamed.teamName(.other) == "Opponent")
        #expect(Game(id: "g_3", scoutedTeam: "").teamName(.scouted) == "Scouted team")
    }

    @Test func noFilmCardAndNotices() throws {
        // 03 §7.3 row 5, §7.7
        #expect(game().showsNoFilmCard(hasAnalysis: false))
        #expect(!game(videoURL: "https://example.com/a.mp4").showsNoFilmCard(hasAnalysis: false))
        #expect(!game().showsNoFilmCard(hasAnalysis: true))

        #expect(game(hasVideo: true).pendingNotice(hasAnalysis: true, latestAnalysisJob: nil, jobPanelVisible: false) == nil)
        #expect(game().pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false) == nil)

        let notAnalyzed = game(status: .uploaded, hasVideo: true).pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false)
        #expect(notAnalyzed == .info(NoticeText(tone: .info, message: "This film hasn't been analyzed yet.", hint: "Click Analyze film to send it to the GPU.")))

        let gpuSaved = game(status: .uploaded, hasVideo: true, tracking: true).pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false)
        #expect(gpuSaved == .info(NoticeText(tone: .info, message: "The GPU results for this film are saved, but the stats have not been built from them yet.", hint: "Click Re-run analysis to build them on this server (about a minute, no GPU).")))

        let reanalyzeJob = Job(id: "j_1", gameID: "g_1", kind: .reanalyze)
        let running = game(status: .processing, hasVideo: true).pendingNotice(hasAnalysis: false, latestAnalysisJob: reanalyzeJob, jobPanelVisible: true)
        #expect(running == .info(NoticeText(tone: .info, message: "Results will appear here when the analysis finishes.", hint: "Re-run analysis takes about a minute on this server.")))
        let gpuRun = game(status: .queued, hasVideo: true).pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: true)
        if case .info(let notice) = gpuRun { #expect(notice.hint == "Long games can take 30-60 minutes on the GPU.") } else { Issue.record("expected info") }

        let failedGame = try Fixture.decode(Game.self, "game_failed.json")
        #expect(failedGame.pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false) == .error(try #require(failedGame.error)))
        #expect(failedGame.pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: true) == .info(NoticeText(tone: .info, message: "There are no results because the analysis failed.", hint: "See the error above and run the analysis again once the problem is fixed.")))

        let ready = game(status: .ready, hasVideo: true).pendingNotice(hasAnalysis: false, latestAnalysisJob: nil, jobPanelVisible: false)
        #expect(ready == .info(NoticeText(tone: .info, message: "The analysis could not be loaded.", hint: "Reload the page; if it keeps happening, re-run the analysis.")))

        #expect(game(hasVideo: true).filmUnavailableNotice(hasAnalysis: true) == nil)
        #expect(game(videoURL: "https://example.com/a.mp4").filmUnavailableNotice(hasAnalysis: true)?.message == "It was analyzed from a video link and isn't stored on this server, so it can't be played here. The stats below still work.")
        #expect(game().filmUnavailableNotice(hasAnalysis: true)?.message == "The film isn't stored on this server, so it can't be played here. The stats below still work.")
        #expect(game().filmUnavailableNotice(hasAnalysis: false) == nil)
    }

    @Test func confirmations() throws {
        // game.js:25-30 / 03 §7.4
        let withResults = Game.fullReanalysisConfirmation(showsResults: true).webText
        #expect(withResults == "Send the film to the GPU again?\n\nA full re-analysis takes about as long as the first run and costs another GPU run. The current results stay on this page until it finishes.\n\nIt numbers the players' tracks again, so it clears the track assignments you made on the Roster page; redo them afterwards.\n\n(Re-run analysis only redoes the stats on this server.)")
        #expect(!Game.fullReanalysisConfirmation(showsResults: false).webText.contains("current results"))
        let game = try Fixture.decode(Game.self, "game_create.json")
        #expect(game.deleteConfirmation.webText == "Delete \"Test Team A vs Test Team B\"?\n\nThis removes the film, analysis, rosters and reports for this game. It cannot be undone.")
        #expect(game.errorSummary == nil)
        #expect(try Fixture.decode(Game.self, "game_failed.json").errorSummary == "This game has no film yet. Upload an MP4 or provide a video URL first.")
    }

    @Test func activeTerminalAndLatestJobs() throws {
        let jobs = try Fixture.decode([Job].self, "jobs_list_game1.json")
        #expect(jobs.allSatisfy { $0.isTerminal } && !jobs.contains { $0.isActive })
        #expect(jobs.latestAnalysisJob?.id == jobs.first?.id)
        #expect(jobs.activeReportJob == nil)

        let report = Job(id: "j_r", gameID: "g_1", kind: .report, status: .running, stage: .reporting)
        let finishedReport = Job(id: "j_r0", gameID: "g_1", kind: .report, status: .succeeded, stage: .done)
        let analysis = Job(id: "j_a", gameID: "g_1", kind: .analyze, status: .failed, stage: .gpuProcessing)
        #expect([finishedReport, report, analysis].latestAnalysisJob?.id == "j_a")
        #expect([finishedReport, report, analysis].activeReportJob?.id == "j_r")
        #expect([finishedReport].latestAnalysisJob == nil)

        let waiting = try Fixture.decode([Job].self, "jobs_list_while_analyzing.json")
        #expect(waiting.first?.isActive == true)
    }

    @Test func failureActionsAndRetryRules() throws {
        // jobpanel.js:175-200, game.js:49-58 (03 §7.5)
        func job(_ kind: JobKind, _ status: JobStatus, _ stage: JobStage, retryable: Bool? = nil) -> Job {
            Job(id: "j_1", gameID: "g_1", kind: kind, status: status, stage: stage,
                error: retryable.map { ErrorInfo(code: "X", title: "t", message: "m", retryable: $0) })
        }
        #expect(job(.analyze, .running, .gpuProcessing).finishedAction == nil)
        #expect(job(.analyze, .succeeded, .done).finishedAction == nil)
        #expect(job(.analyze, .cancelled, .done).finishedAction == .startAgain)
        #expect(job(.analyze, .failed, .analyzing, retryable: false).finishedAction == .rerunAnalysis)
        #expect(job(.analyze, .failed, .reporting, retryable: true).finishedAction == .rerunAnalysis)
        #expect(job(.analyze, .failed, .gpuProcessing, retryable: true).finishedAction == .retry)
        #expect(job(.analyze, .failed, .preparing, retryable: false).finishedAction == nil)
        #expect(job(.reanalyze, .failed, .analyzing).finishedAction == .retry)
        // A job the queue refused: failed at stage done → Retry (09 B4).
        #expect(job(.analyze, .failed, .done, retryable: true).finishedAction == .retry)

        #expect(job(.analyze, .failed, .analyzing).failedPastTheGPU && !job(.analyze, .failed, .analyzing).retriesOnTheGPU)
        #expect(job(.analyze, .cancelled, .done).retriesOnTheGPU)
        #expect(!job(.reanalyze, .cancelled, .done).retriesOnTheGPU)
        #expect(job(.analyze, .cancelled, .done).retryNeedsConfirmation(gameHasTracking: true))
        #expect(!job(.analyze, .cancelled, .done).retryNeedsConfirmation(gameHasTracking: false))

        let failed = try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")
        #expect(failed.finishedAction == nil)
        #expect(failed.failureInfo == failed.error)
        let bare = Job(id: "j_1", gameID: "g_1", kind: .report, status: .failed, stage: .reporting, message: "")
        #expect(bare.failureInfo.title == "Scouting report failed" && bare.failureInfo.message == "The job stopped with an error.")
        #expect(bare.finishedAction == .retry)
    }

    @Test func headerBadgeWhileAJobRuns() throws {
        // game.js:271-283
        let running = try Fixture.decode(Job.self, "job_running_before_cancel.json")
        #expect(running.gameHeaderBadge == BadgeLabel("Processing · 27%", tone: .info))
        #expect(Job(id: "j", gameID: "g", kind: .analyze, status: .running, stage: .preparing).gameHeaderBadge == BadgeLabel("Processing", tone: .info))
        #expect(Job(id: "j", gameID: "g", kind: .analyze).gameHeaderBadge == BadgeLabel("Queued", tone: .info))
        #expect(try Fixture.decode(Job.self, "job_get.json").gameHeaderBadge == nil)
    }

    @Test func elapsedTimeIsNeverNegative() throws {
        let job = try Fixture.decode(Job.self, "job_get.json")
        let started = try #require(job.startedAt)
        #expect(job.elapsedSeconds(now: started.addingTimeInterval(200)) == 200)
        #expect(job.elapsedSeconds(now: started.addingTimeInterval(-30)) == 0)
        #expect(Job(id: "j", gameID: "g", kind: .analyze).elapsedSeconds() == nil)
        #expect(Job(id: "j", gameID: "g", kind: .reanalyze, params: ["report": true]).writesReportAfterwards)
        #expect(!Job(id: "j", gameID: "g", kind: .reanalyze, params: ["report": false]).writesReportAfterwards)
        #expect(Job(id: "j", gameID: "g", kind: .report, params: ["coach_focus": "We play a 2-3 zone"]).coachFocus == "We play a 2-3 zone")
    }

    @Test func teamConfirmationBanner() throws {
        // game.js:322-325 / 06 §5.3
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        #expect(analysis.confirmableTeams.count == 2)
        let unconfirmed = try Fixture.decode(Game.self, "game_ready.json")
        #expect(unconfirmed.teamIDMap.isEmpty)
        #expect(analysis.needsTeamConfirmation(for: unconfirmed))
        let confirmed = try Fixture.decode(Game.self, "game_patch_team_id_map.json")
        #expect(!analysis.needsTeamConfirmation(for: confirmed))
        #expect(analysis.teams.map(\.colorWord) == ["Navy", "White"])
        #expect(TeamSummary(side: .scouted, name: "A", teamID: 0, colorRGB: RGB(red: 240, green: 240, blue: 240), colorName: nil, score: 0).colorWord == "Light")
        #expect(TeamSummary(side: .scouted, name: "A", teamID: 0, colorRGB: RGB(red: 24, green: 34, blue: 76), colorName: nil, score: 0).colorWord == "Dark")
        #expect(RGB(red: 24, green: 34, blue: 76).hexString == "#18224c")
        #expect(RGB(red: 300, green: -4, blue: 15).hexString == "#ff000f")
        #expect(!analysis.freeThrowsMissing)
    }

    /// roster.js:255: `Row ${row ?? "?"}: ${reason ?? "not a player row"}`.
    @Test func skippedRowsReadAsTheWebWritesThem() {
        typealias Row = RosterImportResult.SkippedRow
        #expect(Row(row: 5, reason: "missing jersey number").displayText == "Row 5: missing jersey number")
        #expect(Row(fields: ["row": 7]).displayText == "Row 7: not a player row")
        #expect(Row(fields: ["reason": "blank line"]).displayText == "Row ?: blank line")
        #expect(Row(fields: [:]).displayText == "Row ?: not a player row")
        #expect(Row(fields: ["row": .null, "reason": .null]).displayText == "Row ?: not a player row")
        #expect(Row(fields: ["row": "B12", "reason": ""]).displayText == "Row B12: ")
    }

    /// game.js:322-325: an empty `color_name` is no colour (JavaScript's `""` is falsy).
    @Test func anEmptyColourNameIsNoColour() throws {
        var analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        analysis.teams = [
            TeamSummary(side: .scouted, name: "Test Team A", teamID: 0, colorRGB: nil, colorName: "navy", score: 0),
            TeamSummary(side: .other, name: "Test Team B", teamID: 1, colorRGB: nil, colorName: "", score: 0),
        ]
        #expect(analysis.confirmableTeams.map(\.side) == [.scouted])
        #expect(!analysis.needsTeamConfirmation(for: try Fixture.decode(Game.self, "game_ready.json")))
        analysis.teams[1].colorRGB = RGB(red: 238, green: 238, blue: 236)
        #expect(analysis.confirmableTeams.count == 2)
    }

    /// game.js:314-321 `teamChoiceLabels`.
    @Test func teamChoiceLabels() {
        func team(rgb: [Int]? = nil, name: String? = nil) -> TeamSummary {
            TeamSummary(
                side: .scouted, name: "Test Team A", teamID: 0, colorRGB: rgb.map { RGB(red: $0[0], green: $0[1], blue: $0[2]) },
                colorName: name, score: 0)
        }
        #expect(TeamSummary.teamChoiceLabels(for: [team(name: "navy"), team(name: "white")]) == ["Navy jerseys", "White jerseys"])
        #expect(TeamSummary.teamChoiceLabels(for: [team(rgb: [250, 250, 250]), team()]) == ["Light jerseys", "Dark jerseys"])
        // The same word: lighter / darker by luminance (#282830 ≈ 0.022, #5a2828 ≈ 0.038) …
        #expect(TeamSummary.teamChoiceLabels(for: [team(rgb: [40, 40, 48], name: "dark"), team(rgb: [90, 40, 40], name: "Dark")])
            == ["Dark jerseys (darker)", "Dark jerseys (lighter)"])
        // … numbered when the shades are within 0.005 or one is unknown.
        #expect(TeamSummary.teamChoiceLabels(for: [team(rgb: [40, 40, 48], name: "dark"), team(rgb: [40, 40, 48], name: "dark")])
            == ["Dark jerseys (team 1)", "Dark jerseys (team 2)"])
        #expect(TeamSummary.teamChoiceLabels(for: [team(name: "white"), team(rgb: [250, 250, 250], name: "white")])
            == ["White jerseys (team 1)", "White jerseys (team 2)"])
        // The caller can resolve colour names (the design system's CSS table).
        let byName: (TeamSummary) -> Double? = { $0.colorName == "navy" ? 0.01 : 0.05 }
        #expect(TeamSummary.teamChoiceLabels(for: [team(name: "navy"), team(name: "Navy")], luminance: byName)
            == ["Navy jerseys (darker)", "Navy jerseys (lighter)"])
    }

    @Test func boxScoreDNPAndTimelineText() throws {
        // boxscore.js:40-43 / timeline.js zone text
        let line = BoxScoreLine(player: PlayerRef(jersey: "3", name: "Test Player 6"), minutesEst: 0.5)
        #expect(line.isDNP)
        #expect(!BoxScoreLine(player: PlayerRef(), minutesEst: 1.0).isDNP)
        #expect(!BoxScoreLine(player: PlayerRef(), minutesEst: 0, pf: 1).isDNP)
        #expect(BoxScoreLine(player: PlayerRef(), minutesEst: nil).isDNP)

        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let shot = try #require(analysis.timeline.first { $0.id == "ev_00013" })
        #expect(shot.zoneText == "Paint · paint")
        #expect(analysis.timeline.first?.zoneText == nil)
        #expect(analysis.sortedTimeline.map(\.id) == analysis.timeline.sorted { ($0.t, $0.frame) < ($1.t, $1.frame) }.map(\.id))
        #expect(PlayerRef(jersey: "23").label == "#23")
        #expect(PlayerRef(name: "Test Player 1").label == "Test Player 1")
        #expect(PlayerRef().label == "Unknown player")
        #expect(PlayerRef(jersey: "", name: "").label == "Unknown player")
    }

    @Test func trackRules() throws {
        // 05 §7.5 / §7.9 (roster.js:389-397, 544-599)
        let unmatched = try Fixture.decode(TrackState.self, "tracks_unmatched.json")
        let matched = try Fixture.decode(TrackState.self, "tracks.json")
        // A REANALYZE keeps track ids and the GPU-only fields: the same tracks.
        #expect(unmatched.hasSameTracks(as: matched))
        var renumbered = matched
        renumbered.assignments[0].frames += 1
        #expect(!renumbered.hasSameTracks(as: matched))
        #expect(!TrackState().hasSameTracks(as: matched))

        let first = try #require(matched.assignments.first)
        #expect(first.rankedVotes.map(\.read) == ["14", "4", "74", "1", "11"])
        #expect(abs((first.voteShare(of: "14") ?? 0) - 138.95 / (138.95 + 4.39 + 3.48 + 1.76 + 0.84)) < 1e-12)
        #expect(first.voteShare(of: "99") == nil)
        #expect(TrackAssignment(trackID: 1, votes: ["5": 1, "05": 1]).rankedVotes.map(\.read) == ["05", "5"])

        let unclear = TrackAssignment(trackID: 9, side: .scouted, jersey: nil, bestRead: "5", method: .unrostered)
        #expect(unclear.isUnclearMatch && unclear.howLabel == "Unclear match")
        #expect(!TrackAssignment(trackID: 9, jersey: "5", bestRead: "5", method: .unrostered).isUnclearMatch)
        #expect(TrackAssignment(trackID: 9, jersey: "5", method: .exact).howLabel == "Exact read")

        let sorted = matched.assignments.sorted(by: TrackAssignment.tableOrder)
        #expect(sorted.prefix(12).allSatisfy { $0.isPlayer })
        #expect(sorted.last?.role == "referee")
        let scoutedFirst = sorted.prefix(12).map(\.side)
        #expect(scoutedFirst == scoutedFirst.sorted { ($0 == .scouted ? 0 : 1) < ($1 == .scouted ? 0 : 1) })
        #expect(matched.override(forTrack: 13)?.ignore == true || matched.overrides.isEmpty)
    }

    @Test func jerseys() {
        // 05 §6.1, 09 D1 #4
        #expect(Jersey.isValid("0") && Jersey.isValid("00") && Jersey.isValid("05") && Jersey.isValid("99"))
        #expect(!Jersey.isValid("") && !Jersey.isValid("100") && !Jersey.isValid("5a") && !Jersey.isValid("５") && !Jersey.isValid("٣"))
        #expect(Jersey.normalized("#5") == "5" && Jersey.normalized(" # 23 ") == "23" && Jersey.normalized("#") == nil)
        #expect(Jersey.numericValue("05") == 5 && Jersey.numericValue("5") == 5 && Jersey.numericValue("x") == nil)
        let ordered = ["1", "00", "05", "0", "5", nil, "abc", "10"].sorted { Jersey.sortKey($0) < Jersey.sortKey($1) }
        #expect(ordered == ["0", "00", "1", "5", "05", "10", nil, "abc"])
    }

    @Test func uploadSessionHelpers() throws {
        let partial = try Fixture.decode(UploadSession.self, "upload_get_partial.json")
        #expect(!partial.isFullyReceived && partial.nextChunkLength == 21284)
        #expect(abs(partial.fractionReceived - 20000.0 / 41284.0) < 1e-12)
        #expect(try Fixture.decode(UploadSession.self, "upload_get_full.json").isFullyReceived)
    }

    @Test func calibrationMapsPixelsToCourtFeet() throws {
        let calibration = try Fixture.decode(CourtCalibration.self, "calibration_put_minimal.json")
        // The four clicked corners map back onto their landmarks (exactly 4 points fit exactly, 04 §5.2).
        let corner = try #require(calibration.courtPoint(forPixel: XY(x: 40, y: 330)))
        #expect(abs(corner.x) < 1e-6 && abs(corner.y) < 1e-6)
        let far = try #require(calibration.courtPoint(forPixel: XY(x: 490, y: 120)))
        #expect(abs(far.x - 84) < 1e-6 && abs(far.y - 50) < 1e-6)
        #expect(CourtCalibration(points: [], matrix: [[1]], reprojectionErrorFt: 0).courtPoint(forPixel: XY(x: 0, y: 0)) == nil)
    }
}
