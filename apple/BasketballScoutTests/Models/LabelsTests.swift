import Foundation
import Testing
@testable import BasketballScout

/// The web's label tables, checked against the spec tables (03 §3.2–§3.3, 07 §3.5–§3.6, 06 §5.2, §13.4,
/// 05 §7.5, labels.js).
nonisolated struct LabelsTests {
    @Test func gameStatusBadges() {
        // 07 §3.5
        let table: [(GameStatus, String, StatusTone)] = [
            (.draft, "No film", .neutral), (.uploaded, "Film uploaded", .warning), (.queued, "Queued", .info),
            (.processing, "Processing", .info), (.ready, "Ready", .success), (.failed, "Failed", .danger),
            (.unknown("archived"), "archived", .neutral),
        ]
        for (status, text, tone) in table {
            #expect(status.badge == BadgeLabel(text, tone: tone))
        }
        #expect(GameStatus.queued.isBusy && GameStatus.processing.isBusy)
        #expect(!GameStatus.ready.isBusy && !GameStatus.failed.isBusy && !GameStatus.uploaded.isBusy)
    }

    @Test func jobStageAndKindLabels() {
        // 03 §3.2 / labels.js:117-132
        let stages: [(JobStage, String)] = [
            (.queued, "Waiting for the background worker"), (.preparing, "Preparing the film"),
            (.uploadingToGPU, "Uploading film to the GPU"), (.gpuProcessing, "Analyzing on the GPU"),
            (.downloadingResults, "Downloading results from the GPU"), (.analyzing, "Building box score"),
            (.reporting, "Writing scouting report"), (.done, "Finished"), (.unknown("thinking"), "Working"),
        ]
        for (stage, label) in stages { #expect(stage.label == label) }
        #expect(JobKind.analyze.label == "Film analysis")
        #expect(JobKind.reanalyze.label == "Re-analysis")
        #expect(JobKind.report.label == "Scouting report")
        #expect(JobKind.live.label == "Live analysis")
        #expect(JobKind.unknown("x").label == "Job")
    }

    /// game.js:289, 306, 347: one source for the game page, calibration, Data quality and the roster.
    @Test func jobStartToasts() {
        #expect(JobKind.reanalyze.startedToast == "Re-running the analysis\u{2026}")
        #expect(JobKind.analyze.startedToast == "Analysis started")
        #expect(Labels.fullReanalysisStartedToast == "Full re-analysis started")
        #expect(Labels.teamsConfirmedToast == "Thanks - teams confirmed.")
        #expect(RosterText.rerunStartedToast == JobKind.reanalyze.startedToast)
    }

    @Test func tooLateToCancelTable() {
        // 03 §3.3 / schemas.py:763-780
        for stage in JobStage.knownCases {
            let lateForAnalysis = stage == .analyzing || stage == .reporting
            #expect(Job(id: "j_1", gameID: "g_1", kind: .analyze, status: .running, stage: stage).isTooLateToCancel == lateForAnalysis)
            #expect(Job(id: "j_1", gameID: "g_1", kind: .reanalyze, status: .running, stage: stage).isTooLateToCancel == lateForAnalysis)
            #expect(Job(id: "j_1", gameID: "g_1", kind: .report, status: .running, stage: stage).isTooLateToCancel == (stage == .reporting))
            // labels.js `TOO_LATE_TO_CANCEL.live`: a cancel stops a live job at any stage but `reporting`.
            #expect(Job(id: "j_1", gameID: "g_1", kind: .live, status: .running, stage: stage).isTooLateToCancel == (stage == .reporting))
        }
        #expect(JobKind.unknown("x").tooLateToCancelStages.isEmpty)
    }

    @Test func stageTextPrecedence() {
        // labels.js:147-156: final statuses first, then cancelling, then report jobs, then the stage.
        func job(_ status: JobStatus, _ stage: JobStage, kind: JobKind = .analyze, progress: Double = 0, cancel: Bool = false) -> Job {
            Job(id: "j_1", gameID: "g_1", kind: kind, status: status, stage: stage, progress: progress, cancelRequested: cancel)
        }
        #expect(job(.succeeded, .done).stageText == "Finished")
        #expect(job(.failed, .preparing).stageText == "Failed")
        #expect(job(.cancelled, .done).stageText == "Cancelled")
        #expect(job(.running, .gpuProcessing, progress: 41.5, cancel: true).stageText == "Cancelling…")
        #expect(job(.running, .analyzing, progress: 93, cancel: true).stageText == "Building box score")
        #expect(job(.running, .preparing, kind: .report).stageText == "Writing scouting report")
        #expect(job(.queued, .queued, kind: .report).stageText == "Waiting for the background worker")
        #expect(job(.running, .gpuProcessing, progress: 41.5).stageText == "Analyzing on the GPU (42%)")
        #expect(job(.running, .gpuProcessing, progress: 26.7).stageText == "Analyzing on the GPU (27%)")
        #expect(job(.running, .unknown("x")).stageText == "Working")
    }

    @Test func progressLineOfTheGamesList() throws {
        // 07 §3.6: "Analyzing on the GPU (42%) · 42% · {message}"; after a cancel request no message.
        let running = try Fixture.decode(Job.self, "job_running_before_cancel.json")
        #expect(running.progressText == "Analyzing on the GPU (27%) · 27% · \(running.message)")
        let cancelling = try Fixture.decode(Job.self, "job_cancel_running.json")
        #expect(cancelling.message == "Cancelling...")
        #expect(cancelling.progressNote == nil)
        #expect(cancelling.progressText == "Cancelling… · \(cancelling.progressPercent)%")
        let tooLate = try Fixture.decode(Job.self, "job_cancel_too_late.json")
        #expect(tooLate.isTooLateToCancel)
        #expect(tooLate.progressText == "Building box score · 93% · Cancel requested")
        #expect(Job(id: "j", gameID: "g", kind: .analyze, message: "").progressText == "Waiting for the background worker · 0%")
        #expect(Job.waitingForWorkerText == "Waiting for the worker…")
    }

    @Test func jobPanelTexts() throws {
        let running = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        #expect(running.panelTitle == "Film analysis in progress")
        #expect(running.cancelButtonTitle == "Cancel")
        #expect(running.panelDetails(runningFor: "3 s") == "\(running.progressPercent)% overall · \(running.message) · running for 3 s")
        let cancelling = try Fixture.decode(Job.self, "job_cancel_running.json")
        #expect(cancelling.cancelButtonTitle == "Cancelling…")
        #expect(cancelling.panelDetails(runningFor: nil) == "\(cancelling.progressPercent)% overall")
        let tooLate = try Fixture.decode(Job.self, "job_cancel_too_late.json")
        #expect(tooLate.cancelButtonTitle == "Cancel requested")
        let lateDone = try Fixture.decode(Job.self, "job_late_cancel_2_succeeded_done.json")
        #expect(lateDone.finishedWithWarningsTitle == "Film analysis finished with warnings")
        #expect(lateDone.showsPanel)
        let cancelled = try Fixture.decode(Job.self, "job_cancelled_2_cancelled_done.json")
        #expect(cancelled.cancelledNotice == NoticeText(tone: .info, title: "Film analysis was cancelled", message: "Start it again whenever you are ready."))
    }

    @Test func cancelQuestions() {
        // 03 §7.5 cancelQuestion
        func question(_ kind: JobKind, _ stage: JobStage, report: Bool = false) -> String {
            Job(id: "j", gameID: "g", kind: kind, status: .running, stage: stage, params: report ? ["report": true] : [:]).cancelQuestion.webText
        }
        #expect(question(.analyze, .gpuProcessing) == "Stop this job? You can start it again later.")
        #expect(question(.report, .queued) == "Stop this job? You can start it again later.")
        #expect(question(.report, .reporting) == "Too late to cancel: Claude is already writing the scouting report.\n\nIt will finish on its own, and the report is kept.")
        #expect(question(.analyze, .reporting) == "Too late to cancel: the analysis is finished and Claude is already writing the scouting report.\n\nThe job will finish on its own, and the report is kept.")
        #expect(question(.reanalyze, .reporting) == question(.analyze, .reporting))
        #expect(question(.reanalyze, .analyzing, report: true) == "Too late to stop the re-analysis: it is already redoing the stats (about a minute), so it will finish.\n\nCancelling now only skips the automatic scouting report.")
        #expect(question(.reanalyze, .analyzing) == "Too late to stop the re-analysis: it is already redoing the stats (about a minute), so it will finish.\n\nThere is nothing left to cancel.")
        #expect(question(.analyze, .analyzing) == "Too late to stop the analysis: the new GPU results are already in place, so it will finish.\n\nCancelling now only skips the automatic scouting report, if one was going to be written.")
    }

    @Test func eventLabelsAndCategories() {
        // 06 §13.4 (labels.js:5-24) and §5.2 categories (labels.js:27-46).
        let table: [(EventType, String, EventCategory)] = [
            (.shotMade, "Made shot", .make), (.shotMissed, "Missed shot", .miss), (.freeThrowMade, "Free throw made", .make),
            (.freeThrowMissed, "Free throw missed", .miss), (.offensiveRebound, "Offensive rebound", .rebound),
            (.defensiveRebound, "Defensive rebound", .rebound), (.assist, "Assist", .assist), (.steal, "Steal", .defense),
            (.block, "Block", .defense), (.turnover, "Turnover", .turnover), (.foul, "Foul", .foul), (.screen, "Screen", .other),
            (.pass, "Pass", .other), (.jumpBall, "Jump ball", .game), (.periodStart, "Period start", .game),
            (.periodEnd, "Period end", .game), (.timeout, "Timeout", .game), (.possessionChange, "Possession change", .other),
            (.unknown("alley_oop"), "alley oop", .other),
        ]
        for (type, label, category) in table {
            #expect(type.label == label)
            #expect(type.category == category)
        }
        #expect(EventType.knownCases.filter(\.isNoisy) == [.screen, .pass, .possessionChange])
        #expect(EventCategory.allCases.map(\.label) == ["Makes", "Misses", "Rebounds", "Assists", "Steals / blocks", "Turnovers", "Fouls", "Game events", "Other"])
        #expect(EventCategory.allCases.map(\.key) == ["make", "miss", "rebound", "assist", "defense", "turnover", "foul", "game", "other"])
        #expect(EventType.shotMade.secondaryPlayerPrefix == "ast.")
        #expect(EventType.turnover.secondaryPlayerPrefix == "stolen by")
        #expect(EventType.offensiveRebound.secondaryPlayerPrefix == "with")
    }

    @Test func playZoneOutcomeAndRoleLabels() {
        #expect(PlayType.knownCases.map(\.label) == [
            "Pick & Roll", "Pick & Pop", "Isolation", "Fast Break", "Post-Up", "Dribble Handoff", "Off-Ball Screen",
            "Spot-Up", "Cut", "Putback", "Man-to-Man Defense", "Zone Defense", "Full-Court Press",
        ])
        #expect(PlayType.knownCases.filter { $0.category == .defense } == [.manDefense, .zoneDefense, .press])
        #expect(PlayType.unknown("x").category == nil)
        #expect(PlayOutcome.knownCases.map(\.label) == ["Made FG", "Missed FG", "Turnover", "Foul", "No shot", "–"])
        #expect(ShotZone.knownCases.map(\.label) == ["Paint", "Mid-range", "3-point", "Unknown"])
        #expect(ShotZone.unknownZone.zoneTableLabel == "Unknown zone")
        #expect(ShotZone.unknownZone.boxScoreColumnLabel == "No location")
        #expect(ShotZone.paint.zoneTableLabel == "Paint")
        let roles = ["ball_handler", "screener", "post_player", "cutter", "shooter", "passer", "receiver", "defender", "rebounder", "trailer_big"]
        #expect(roles.map(Labels.roleLabel(for:)) == ["Ball handler", "Screener", "Post", "Cutter", "Shooter", "Passer", "Receiver", "Defender", "Rebounder", "trailer big"])
        #expect(Labels.subzoneLabel("left_wing_3") == "left wing 3")
    }

    @Test func trackMethodLabels() {
        // 05 §7.5 / roster.js:25-27
        #expect(TrackMethod.knownCases.map(\.label) == ["Exact read", "Close read", "Partial read", "Set by you", "Not on roster", "No readable jersey"])
        #expect(TrackMethod.unknown("guess").label == "guess")
    }

    @Test func otherSmallTables() {
        #expect(TeamSide.scouted.rosterTitle == "Scouted team" && TeamSide.other.rosterTitle == "Their opponent in this film")
        #expect(TeamSide.scouted.shortTitle == "Scouted team" && TeamSide.other.shortTitle == "Opponent")
        #expect(TeamSide.scouted.opposite == .other && TeamSide.other.opposite == .scouted && TeamSide.unknown("x").opposite == nil)
        #expect(WarningSeverity.info.tone == .info && WarningSeverity.warning.tone == .warning)
        #expect(WarningSeverity.error.tone == .danger && WarningSeverity.unknown("fatal").tone == .warning)
        #expect(ThreatLevel.high.label == "High" && ThreatLevel.high.tone == .danger)
        #expect(ThreatLevel.medium.tone == .warning && ThreatLevel.low.tone == .success)
        #expect(CoordMode.court.label == "Court feet" && CoordMode.pixel.label == "Video pixels only")
        #expect(RosterImportMode.replace.label == "Replace this roster" && RosterImportMode.merge.label == "Merge (update matching jerseys)")
        #expect(HealthState.ok.label == "OK" && HealthState.degraded.label == "Needs attention")
        #expect(VideoVariant.annotated.label == "Annotated")
        #expect(Labels.importColumnLabel(for: "fastscout_name") == "FastScout name")
        #expect(Labels.importColumnLabel(for: "suffix") == "suffix")
        #expect(FinishedJobAction.startAgain.title == "Start again" && FinishedJobAction.rerunAnalysis.title == "Re-run analysis")
    }

    @Test func landmarkLabels() throws {
        // labels.js:192-216 / 04 §5.1
        #expect(Labels.landmarkLabel(for: "left_ft_line_near") == "Left end: free-throw line, near elbow")
        #expect(Labels.landmarkLabel(for: "right_three_corner_far") == "Right end: 3-point line meets baseline (far corner)")
        #expect(Labels.landmarkLabel(for: "center") == "Center of the court")
        #expect(Labels.landmarkLabel(for: "midcourt_near") == "Half-court line at the near sideline")
        #expect(Labels.landmarkLabel(for: "left_hash_mark") == "Left end: hash mark")
        #expect(Labels.landmarkLabel(for: "top_of_key") == "top of key")
        let landmarks = try Fixture.decode(CourtLandmarks.self, "court_landmarks.json")
        #expect(landmarks.landmarks.allSatisfy { !$0.label.contains("_") })
        #expect(CourtLandmark.Group.leftEnd.title == "Left end (as the camera sees it)")
        #expect(CourtLandmark.Group.middle.title == "Middle of the court")
    }

    @Test func agoText() {
        // ui.js formatAgo (07 §5.5)
        #expect(Labels.ago(seconds: nil) == "never")
        #expect(Labels.ago(seconds: 26.1) == "26 s ago")
        #expect(Labels.ago(seconds: 89.4) == "89 s ago")
        #expect(Labels.ago(seconds: 120.4) == "2 min ago")
        #expect(Labels.ago(seconds: 600) == "10 min ago")
        #expect(Labels.ago(seconds: 5399) == "90 min ago")
        #expect(Labels.ago(seconds: 7200) == "2 h ago")
    }

    @Test func calibrationFit() {
        func fit(_ error: Double) -> BadgeLabel {
            CourtCalibration(points: [], matrix: [], reprojectionErrorFt: error).fitQuality
        }
        #expect(fit(0) == BadgeLabel("Excellent fit", tone: .success))
        #expect(fit(1.486) == BadgeLabel("Good fit", tone: .success))
        #expect(fit(4) == BadgeLabel("Fair fit - double-check the points", tone: .warning))
        #expect(fit(7) == BadgeLabel("Poor fit - some points are probably on the wrong landmark", tone: .danger))
    }

    @Test func healthNotices() throws {
        // index.js:120-130 order and wording; labels.js:162-173 worker warning.
        let fixture = try Fixture.decode(HealthStatus.self, "health.json")
        #expect(fixture.workerNotice == nil)
        #expect(fixture.notices.map(\.title) == [
            "Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.",
            "Claude is not configured, so scouting reports can't be written.",
            "ffmpeg is not installed on the server, so uploaded film can't be checked before processing.",
        ])
        #expect(fixture.workerLastSeenText == "26 s ago" && fixture.queueText == "sqlite OK" && fixture.isModalOK)

        let degraded = try Fixture.decode(HealthStatus.self, "health_degraded.json")
        #expect(degraded.isWorkerStale && !degraded.isWorkerHealthy)
        #expect(degraded.workerNotice?.title == "The background worker was last seen 2 min ago - it may have stopped.")
        #expect(degraded.workerNotice?.tone == .danger)

        let broken = HealthStatus(status: .degraded, version: "0.1.0", processor: "modal", queueBackend: "redis", queueOK: false, modalConfigured: false, claudeConfigured: true, ffmpegAvailable: true, workerLastSeenS: nil)
        #expect(broken.notices.map(\.title) == [
            "The background worker is not running - start basketball-scout-worker.",
            "The job queue (redis) is not reachable.",
            "Modal (the GPU service) is not configured, so film cannot be analyzed.",
        ])
        #expect(broken.queueText == "redis down" && !broken.isModalOK && broken.workerLastSeenText == "never")
    }
}
