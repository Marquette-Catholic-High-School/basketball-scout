#if os(iOS)
import XCTest

/// The game page on iPhone (03 §7.3–§7.7): header, the "Game actions" menu and its enable rules, the
/// "No film yet" card and pending notice, Re-run analysis, Full re-analysis (asks first), the job panel
/// (stages, Cancel question, cancelled state with Start again) and the team banner.
final class iPhoneGamePageTests: XCTestCase {
    /// An analysed game: the header (title, team chips, date, level, location, badge) and the four actions
    /// with their help texts (03 §7.4).
    @MainActor
    func testHeaderAndActionsOfAnAnalysedGame() async throws {
        let kit = try iPhoneKit(self, tag: "header")
        let api = kit.api
        let team = "iPT Header \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let header = kit.app.otherElements["\(team) versus Test Opponent. Nov 7, 2026. Varsity. Test Gym. Status: Ready"]
        XCTAssertTrue(kit.wait(header, 10), "the header does not read as one sentence with the game's facts")
        kit.shot("header")
        kit.openGameActions()
        XCTAssertTrue(kit.button("Roster & jerseys").exists)
        XCTAssertTrue(kit.button("Replace film").exists, "a game with film offers Add film")
        let rerun = kit.button("Re-run analysis, Redo the stats on this server (about a minute, no GPU)")
        XCTAssertTrue(rerun.exists && rerun.isEnabled, "no enabled Re-run analysis")
        let full = kit.button("Full re-analysis, Send the film to the GPU again")
        XCTAssertTrue(full.exists && full.isEnabled, "no enabled Full re-analysis")
        kit.shot("actions")
        kit.tapOutside()
    }

    /// A game without film: "No film yet" with Add film (03 §7.3 row 5); the menu says "Add film" and
    /// "Analyze film" (disabled: nothing to analyze), without Full re-analysis.
    @MainActor
    func testGameWithoutFilm() async throws {
        let kit = try iPhoneKit(self, tag: "no-film")
        let api = kit.api
        let team = "iPT No Film \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.any("No film yet"), 10))
        XCTAssertTrue(kit.any("Upload the game film (MP4) or give a direct video link to start the analysis.").exists)
        XCTAssertTrue(kit.exact("No film").exists, "no No film badge")
        kit.shot("no-film")
        kit.openGameActions()
        XCTAssertTrue(kit.button("Add film").exists)
        let analyze = kit.buttonStarting("Analyze film")
        XCTAssertTrue(analyze.exists, "no Analyze film item")
        XCTAssertFalse(analyze.isEnabled, "Analyze film is enabled without film")
        XCTAssertFalse(kit.buttonStarting("Full re-analysis").exists, "Full re-analysis offered without GPU results")
        kit.shot("actions")
        kit.tapOutside()
        kit.tapButton("Add film")
        XCTAssertTrue(kit.wait(kit.app.navigationBars["Add film"], 10), "Add film did not open the film screen")
        XCTAssertTrue(kit.any("Game film").exists)
    }

    /// Film uploaded but not analyzed: the pending notice (03 §7.7) and "Analyze film", which starts the
    /// analysis without asking (toast "Analysis started") and shows the job panel until the game is ready.
    @MainActor
    func testAnalyzeUploadedFilm() async throws {
        let kit = try iPhoneKit(self, tag: "analyze")
        let api = kit.api
        let team = "iPT Analyze \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneCreateGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        try await api.iPhoneUploadFilm(gameID: gameID, film: ScoutUITestFilm.url(), autoStart: false)
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.any("This film hasn't been analyzed yet."), 10), "no pending notice")
        XCTAssertTrue(kit.any("Click Analyze film to send it to the GPU.").exists)
        XCTAssertTrue(kit.exact("Film uploaded").exists)
        kit.shot("pending")
        kit.gameAction("Analyze film")
        XCTAssertTrue(kit.wait(kit.any("Analysis started"), 10), "no Analysis started toast")
        let panel = kit.any("Film analysis in progress")
        if panel.waitForExistence(timeout: 5) { kit.shot("job-panel") }
        XCTAssertTrue(kit.wait(kit.exact("Ready"), 90), "the analysis did not finish")
        XCTAssertTrue(kit.waitGone(panel, 10), "the job panel stayed after the analysis")
        XCTAssertTrue(kit.wait(kit.app.scrollViews["Analysis sections"], 10), "no analysis tabs after the analysis")
        kit.shot("ready")
    }

    /// "Re-run analysis" starts a re-analysis at once (no question; toast "Re-running the analysis…") and the
    /// page follows it to the end.
    @MainActor
    func testRerunAnalysis() async throws {
        let kit = try iPhoneKit(self, tag: "rerun")
        let api = kit.api
        let team = "iPT Rerun \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let jobsBefore = try await api.iPhoneJobs(gameID).count
        kit.gameAction("Re-run analysis")
        XCTAssertFalse(kit.app.alerts.firstMatch.waitForExistence(timeout: 1), "Re-run analysis asked first (the web does not)")
        XCTAssertTrue(kit.wait(kit.any("Re-running the analysis"), 10), "no Re-running the analysis… toast")
        kit.shot("rerun-started")
        try await api.iPhoneWaitLatestJob(gameID, status: ["succeeded"], timeout: 90)
        let jobs = try await api.iPhoneJobs(gameID)
        XCTAssertEqual(jobs.count, jobsBefore + 1)
        XCTAssertEqual(jobs.first?["kind"] as? String, "reanalyze")
        XCTAssertTrue(kit.wait(kit.exact("Ready"), 30))
        XCTAssertTrue(kit.waitGone(kit.any("Re-analysis in progress"), 15), "the job panel stayed after the re-run")
        kit.shot("rerun-done")
    }

    /// "Full re-analysis" asks with the web's text first; Cancel starts nothing. "Send to GPU" starts it
    /// (toast), the job panel shows the stage and a Cancel whose question offers "Keep running".
    @MainActor
    func testFullReanalysisAsksFirst() async throws {
        let kit = try iPhoneKit(self, tag: "full")
        let app = kit.app
        let api = kit.api
        let team = "iPT Full \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let jobsBefore = try await api.iPhoneJobs(gameID).count
        kit.gameAction("Full re-analysis")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(kit.wait(alert, 5), "Full re-analysis did not ask first")
        XCTAssertTrue(alert.staticTexts["Send the film to the GPU again?"].exists)
        XCTAssertTrue(kit.any("A full re-analysis takes about as long as the first run and costs another GPU run.").exists)
        XCTAssertTrue(kit.any("(Re-run analysis only redoes the stats on this server.)").exists)
        kit.shot("question")
        kit.tap(kit.alertButton("Cancel"))
        kit.pause(1)
        let jobsAfterCancel = try await api.iPhoneJobs(gameID).count
        XCTAssertEqual(jobsAfterCancel, jobsBefore, "Cancel started a job")

        kit.gameAction("Full re-analysis")
        kit.tap(kit.alertButton("Send to GPU"))
        XCTAssertTrue(kit.wait(kit.any("Full re-analysis started"), 10), "no Full re-analysis started toast")
        let panelTitle = kit.any("Film analysis in progress")
        if panelTitle.waitForExistence(timeout: 6) {
            kit.shot("job-panel")
            let cancel = kit.button("Cancel")
            if cancel.exists, cancel.isEnabled {
                cancel.tap()
                if alert.waitForExistence(timeout: 5) {
                    // "Stop this job?…" while it can still be stopped, else the too-late text.
                    XCTAssertTrue(app.alerts.buttons["Keep running"].exists, "the cancel question has no Keep running")
                    kit.shot("cancel-question")
                    kit.tap(kit.alertButton("Keep running"))
                }
            }
        }
        try await api.iPhoneWaitLatestJob(gameID, status: ["succeeded"], timeout: 90)
        XCTAssertTrue(kit.wait(kit.exact("Ready"), 30))
        let latest = try await api.iPhoneJobs(gameID).first
        XCTAssertEqual(latest?["kind"] as? String, "analyze")
        kit.shot("done")
    }

    /// A cancelled analysis: the panel says so and offers "Start again", which asks first (it goes to the
    /// GPU again) and then runs the analysis (03 §7.5).
    @MainActor
    func testCancelledAnalysisOffersStartAgain() async throws {
        let kit = try iPhoneKit(self, tag: "cancelled")
        let api = kit.api
        let team = "iPT Cancelled \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let job = try await api.iPhoneStartJob(gameID, kind: "analyze")
        let jobID = try XCTUnwrap(job["id"] as? String)
        try await api.iPhoneCancelJob(jobID)
        try await api.iPhoneWaitLatestJob(gameID, status: ["cancelled", "succeeded"], timeout: 60)
        let status = try await api.iPhoneJobs(gameID).first?["status"] as? String
        try XCTSkipIf(status != "cancelled", "the server finished the job before the cancel arrived")
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        XCTAssertTrue(kit.wait(kit.any("Film analysis was cancelled"), 10), "no cancelled notice")
        XCTAssertTrue(kit.any("Start it again whenever you are ready.").exists)
        kit.shot("cancelled")
        kit.tapButton("Start again")
        if kit.app.alerts.firstMatch.waitForExistence(timeout: 4) {
            XCTAssertTrue(kit.app.alerts.staticTexts["Send the film to the GPU again?"].exists)
            kit.shot("start-again-question")
            kit.tap(kit.alertButton("Send to GPU"))
        }
        try await api.iPhoneWaitLatestJob(gameID, status: ["succeeded"], timeout: 90)
        XCTAssertTrue(kit.waitGone(kit.any("Film analysis was cancelled"), 30), "the cancelled notice stayed")
        kit.shot("started-again")
    }

    /// The team banner: picking the colour the analysis already has as the scouted team confirms it
    /// ("Thanks - teams confirmed.") and the banner goes (03 §7.6).
    @MainActor
    func testTeamBannerConfirmsTeams() async throws {
        let kit = try iPhoneKit(self, tag: "banner")
        let api = kit.api
        let team = "iPT Banner \(Int.random(in: 100...999))"
        let gameID = try await api.iPhoneAnalysedGame(team: team)
        addTeardownBlock { await api.deleteGame(gameID) }
        let analysis = try await api.send("GET", "/api/games/\(gameID)/analysis") as? [String: Any]
        let teams = analysis?["teams"] as? [[String: Any]] ?? []
        let scouted = try XCTUnwrap(teams.first { ($0["side"] as? String) == "scouted" })
        let colour = try XCTUnwrap(scouted["color_name"] as? String, "the analysis has no colour for the scouted team")
        kit.launchSignedIn()
        kit.openGame(titled: "\(team) vs Test Opponent")
        let banner = kit.any("Which team is \(team)?")
        XCTAssertTrue(kit.wait(banner, 10), "no team banner")
        XCTAssertTrue(kit.any("The analysis split the players by jersey colour.").exists)
        kit.shot("banner")
        kit.tap(kit.buttonStarting(colour.prefix(1).uppercased() + colour.dropFirst() + " jerseys"))
        XCTAssertTrue(kit.wait(kit.any("Thanks - teams confirmed."), 10), "no confirmation toast")
        XCTAssertTrue(kit.waitGone(banner, 10), "the banner stayed")
        kit.shot("confirmed")
        let game = try await api.iPhoneGame(gameID)
        XCTAssertEqual((game["team_id_map"] as? [String: String])?.values.sorted(), ["other", "scouted"])
    }
}
#endif
