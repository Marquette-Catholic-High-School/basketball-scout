import Foundation
import Testing
@testable import BasketballScout

/// One row of the games list (07 §3.4 card, §3.5 badges, §3.6 progress block; 04 §6.1 for this device's
/// uploads), checked against the captured server answers.
struct GamesRowModelTests {
    private let enUS = Locale(identifier: "en_US")

    private func makeRow(_ game: Game, job: Job? = nil, upload: UploadState? = nil, isDeleting: Bool = false) -> GamesRowModel {
        GamesRowModel(game: game, job: job, upload: upload, isDeleting: isDeleting, locale: enUS)
    }

    private func upload(
        _ phase: UploadPhase, status: String, sent: Int = 425_000_000, total: Int = 1_000_000_000,
        speed: Double? = nil, reason: UploadPauseReason? = nil
    ) -> UploadState {
        UploadState(
            gameID: "g_3864d2c4f9c8", fileName: "test-film.mp4", phase: phase, statusText: status, pauseReason: reason,
            bytesSent: sent, totalBytes: total, bytesPerSecond: speed)
    }

    // MARK: - The card (07 §3.4)

    @Test func aGameWithoutFilm() throws {
        let row = makeRow(try Fixture.decode(Game.self, "game_get.json"))
        #expect(row.id == "g_e934f8c21058")
        #expect(row.title == "Test Team A vs Test Team B")
        #expect(row.matchup == nil)  // the title already is the matchup
        #expect(row.badges == [GamesRowBadge(text: "No film", tone: .neutral)])
        #expect(row.details == "Nov 7, 2026 \u{00B7} Varsity \u{00B7} Test Gym")
        #expect(row.film == nil)
        #expect(row.errorLine == nil)
        #expect(row.analysis == nil)
        #expect(row.upload == nil)
        #expect(row.filmAction == .addFilm)
        #expect(row.stripe == TeamPalette.darkPreset)  // "dark" → #1f2937
        #expect(!row.isDeleting)
    }

    @Test func aTitleTheCoachSetShowsTheMatchupUnderIt() throws {
        let link = makeRow(try Fixture.decode(Game.self, "game_create_for_link.json"))
        #expect(link.title == "Link fixture game")
        #expect(link.matchup == "Test Team D vs Test Team E")

        var alone = try Fixture.decode(Game.self, "game_create_minimal.json")  // no opponent, no title
        #expect(makeRow(alone).title == "Test Team C")
        #expect(makeRow(alone).matchup == nil)
        alone.title = "Test Scrimmage"
        alone.displayTitle = "Test Scrimmage"
        #expect(makeRow(alone).matchup == "Test Team C")
    }

    @Test func missingFactsAreLeftOutNotShownAsPlaceholders() throws {
        var game = try Fixture.decode(Game.self, "game_get.json")
        game.gameDate = nil
        game.location = "  "
        #expect(makeRow(game).details == "Varsity")
        game.level = nil
        #expect(makeRow(game).details == nil)
        #expect(makeRow(try Fixture.decode(Game.self, "game_create_minimal.json")).details == nil)
    }

    @Test func theStripeIsTheJerseyHintOnly() throws {
        var game = try Fixture.decode(Game.self, "game_get.json")
        game.scoutedColor = "light"
        #expect(makeRow(game).stripe == TeamPalette.lightPreset)
        game.scoutedColor = "#abc"
        #expect(makeRow(game).stripe?.hexString == "#aabbcc")
        game.scoutedColor = "Navy"
        #expect(makeRow(game).stripe?.hexString == "#000080")
        game.scoutedColor = "not a colour"
        #expect(makeRow(game).stripe == nil)
        game.scoutedColor = nil
        #expect(makeRow(game).stripe == nil)
    }

    @Test func filmIsNamedAndALinkCountsAsFilm() throws {
        let link = makeRow(try Fixture.decode(Game.self, "game_link_ready.json"))
        #expect(link.badges == [GamesRowBadge(text: "Ready", tone: .success)])
        #expect(link.film == "Film: Test Team D film.mp4")
        #expect(link.filmAction == nil)  // index.js: "Add film" only when `!has_video && !video_url`

        let uploaded = makeRow(try Fixture.decode(Game.self, "game_ready.json"))
        #expect(uploaded.film == "Film: test-film.mp4")
        #expect(uploaded.filmAction == nil)
    }

    // MARK: - Badges (07 §3.5) and the progress block (07 §3.6)

    @Test func everyStatusHasTheWebsBadge() throws {
        var game = try Fixture.decode(Game.self, "game_ready.json")
        let expected: [(GameStatus, String, ScoutTone)] = [
            (.draft, "No film", .neutral), (.uploaded, "Film uploaded", .warning), (.queued, "Queued", .info),
            (.processing, "Processing", .info), (.ready, "Ready", .success), (.failed, "Failed", .danger),
            (.unknown("archived"), "archived", .neutral),
        ]
        for (status, text, tone) in expected {
            game.status = status
            game.error = nil
            #expect(makeRow(game).badges == [GamesRowBadge(text: text, tone: tone)], "\(status.rawValue)")
        }
    }

    @Test func aQueuedGameWhoseJobCouldNotBeLoadedWaitsForTheWorker() throws {
        let row = makeRow(try Fixture.decode(Game.self, "game_queued.json"))
        #expect(row.badges == [GamesRowBadge(text: "Queued", tone: .info)])
        #expect(row.analysis == GamesRowProgress(
            text: "Waiting for the worker\u{2026}", bar: .indeterminate, accessibilityLabel: "Processing progress"))
        #expect(row.filmAction == nil)
    }

    @Test func aRunningJobShowsItsPercentInTheBadgeAndItsStageLine() throws {
        let game = try Fixture.decode(Game.self, "game_processing.json")
        let job = try Fixture.decode(Job.self, "job_analyze_1_running_gpu_processing.json")
        let row = makeRow(game, job: job)
        #expect(row.badges == [GamesRowBadge(text: "Processing \u{00B7} 5%", tone: .info)])
        // The web really repeats the percent at the GPU stage (07 §3.6).
        #expect(row.analysis?.text == "Analyzing on the GPU (5%) \u{00B7} 5% \u{00B7} Demo mode: simulating GPU processing (0%)")
        #expect(row.analysis?.bar == .value(0.05))
        #expect(row.analysis?.accessibilityLabel == "Processing progress")
    }

    @Test func aQueuedJobSaysQueued() throws {
        let game = try Fixture.decode(Game.self, "game_queued.json")
        let job = try Fixture.decode(Job.self, "job_reanalyze_1_queued_queued.json")
        let row = makeRow(game, job: job)
        #expect(row.badges == [GamesRowBadge(text: "Queued", tone: .info)])
        #expect(row.analysis?.text == "Waiting for the background worker \u{00B7} 0% \u{00B7} Waiting for a worker")
        #expect(row.analysis?.bar == .value(0))
    }

    @Test func aCancelRequestReplacesTheServersMessage() throws {
        let game = try Fixture.decode(Game.self, "game_processing.json")
        let stoppable = try Fixture.decode(Job.self, "job_cancel_running.json")
        #expect(makeRow(game, job: stoppable).analysis?.text == "Cancelling\u{2026} \u{00B7} 27%")
        #expect(makeRow(game, job: stoppable).analysis?.bar == .value(0.27))

        let tooLate = try Fixture.decode(Job.self, "job_late_cancel_1_running_analyzing.json")
        #expect(makeRow(game, job: tooLate).analysis?.text == "Building box score \u{00B7} 93% \u{00B7} Cancel requested")
        #expect(makeRow(game, job: tooLate).badges == [GamesRowBadge(text: "Processing \u{00B7} 93%", tone: .info)])
    }

    @Test func aGameThatIsNotBusyHasNoProgressBlock() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let finished = try Fixture.decode(Job.self, "job_get.json")
        let row = makeRow(game, job: finished)
        #expect(row.analysis == nil)
        #expect(row.badges == [GamesRowBadge(text: "Ready", tone: .success)])
    }

    // MARK: - A failed analysis

    @Test func aFailedAnalysisShowsItsErrorTitleAndMessage() throws {
        let row = makeRow(try Fixture.decode(Game.self, "game_failed.json"))
        #expect(row.badges == [GamesRowBadge(text: "Failed", tone: .danger), GamesRowBadge(text: "No video", tone: .danger)])
        #expect(row.errorLine == "This game has no film yet. Upload an MP4 or provide a video URL first.")
        #expect(row.analysis == nil)
    }

    @Test func aHintWithServerCommandsIsLeftForTheGamePage() throws {
        var game = try Fixture.decode(Game.self, "game_failed.json")
        game.error = ErrorInfo(
            code: "QUEUE_UNAVAILABLE", title: "Job queue unavailable", message: "The job queue (Redis) could not be reached.",
            hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.", retryable: true)
        let row = makeRow(game)
        #expect(row.errorLine == "The job queue (Redis) could not be reached.")
        #expect(row.badges.last == GamesRowBadge(text: "Job queue unavailable", tone: .danger))

        game.error?.hint = nil
        #expect(makeRow(game).errorLine == "The job queue (Redis) could not be reached.")
    }

    // MARK: - This device's upload (04 §6.1)

    @Test func anUploadOnThisDeviceShowsItsProgress() throws {
        let game = try Fixture.decode(Game.self, "game_create_minimal.json")
        let row = makeRow(game, upload: upload(.uploading, status: "Uploading\u{2026}", speed: 12_500_000))
        #expect(row.badges == [
            GamesRowBadge(text: "No film", tone: .neutral), GamesRowBadge(text: "Uploading \u{00B7} 42%", tone: .info),
        ])
        #expect(row.upload == GamesRowProgress(
            text: "test-film.mp4 \u{00B7} Uploading\u{2026} \u{00B7} 42.5% \u{00B7} about 46 s left",
            bar: .value(0.425), accessibilityLabel: "Upload progress"))
        #expect(row.filmAction == .showUpload)
    }

    @Test func aRetryingUploadShowsTheConnectionProblem() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")  // replacing the film of a ready game
        let row = makeRow(game, upload: upload(.uploading, status: "Connection problem - retrying in 4 s (attempt 3 of 8)"))
        #expect(row.badges == [
            GamesRowBadge(text: "Ready", tone: .success), GamesRowBadge(text: "Uploading \u{00B7} 42%", tone: .info),
        ])
        #expect(row.upload?.text == "test-film.mp4 \u{00B7} Connection problem - retrying in 4 s (attempt 3 of 8) \u{00B7} 42.5%")
        #expect(row.filmAction == .showUpload)
    }

    @Test func aPausedUploadSaysWhy() throws {
        let game = try Fixture.decode(Game.self, "game_create_minimal.json")
        let row = makeRow(game, upload: upload(.paused, status: "Paused until you sign in again", reason: .signedOut))
        #expect(row.badges.last == GamesRowBadge(text: "Upload paused", tone: .warning))
        #expect(row.upload == GamesRowProgress(
            text: "test-film.mp4 \u{00B7} Paused until you sign in again \u{00B7} 42.5%", bar: .value(0.425),
            accessibilityLabel: "Upload progress"))
    }

    @Test func aStoppedUploadNamesTheProblemWithoutABar() throws {
        let game = try Fixture.decode(Game.self, "game_create_minimal.json")
        let failure = DisplayError(title: "Can't reach the server", message: "The app could not reach the server.", isRetryable: true)
        let row = makeRow(game, upload: upload(.failed(failure), status: "Stopped"))
        #expect(row.badges.last == GamesRowBadge(text: "Upload stopped", tone: .danger))
        #expect(row.upload == GamesRowProgress(
            text: "test-film.mp4 \u{00B7} Stopped \u{00B7} Can't reach the server", bar: .none, accessibilityLabel: "Upload progress"))
        #expect(row.filmAction == .showUpload)  // the film screen offers Resume / Choose another file
    }

    @Test func startingAndFinishingUploadsShowASlidingBar() throws {
        let game = try Fixture.decode(Game.self, "game_create_minimal.json")
        let starting = makeRow(game, upload: upload(.preparing, status: "Starting upload\u{2026}", sent: 0, total: 0))
        #expect(starting.badges.last == GamesRowBadge(text: "Uploading", tone: .info))
        #expect(starting.upload == GamesRowProgress(
            text: "test-film.mp4 \u{00B7} Starting upload\u{2026}", bar: .indeterminate, accessibilityLabel: "Upload progress"))

        let finishing = makeRow(game, upload: upload(.completing, status: "Finishing upload\u{2026}", sent: 1_000_000_000))
        #expect(finishing.badges.last == GamesRowBadge(text: "Finishing upload", tone: .info))
        #expect(finishing.upload?.text == "test-film.mp4 \u{00B7} Finishing upload\u{2026}")
        #expect(finishing.upload?.bar == .indeterminate)
    }

    @Test func finishedAndCancelledUploadsAreNotShown() throws {
        let game = try Fixture.decode(Game.self, "game_create_minimal.json")
        for phase in [UploadPhase.finished, .cancelled] {
            let row = makeRow(game, upload: upload(phase, status: ""))
            #expect(row.badges == [GamesRowBadge(text: "No film", tone: .neutral)], "\(phase)")
            #expect(row.upload == nil)
            #expect(row.filmAction == .addFilm)
        }
    }

    @Test func theUploadBadgeNeverSays100PercentBeforeTheFilmIsSaved() {
        #expect(GamesRowModel.wholePercent(0.999) == 99)
        #expect(GamesRowModel.wholePercent(0.425) == 42)
        #expect(GamesRowModel.wholePercent(1) == 100)
        #expect(GamesRowModel.wholePercent(1.5) == 100)
        #expect(GamesRowModel.wholePercent(-1) == 0)
        #expect(GamesRowModel.wholePercent(.nan) == 0)
    }

    @Test func aDeleteInProgressIsCarried() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        #expect(makeRow(game, isDeleting: true).isDeleting)
        #expect(!makeRow(game).isDeleting)
    }

    @Test func theFilmActionsAreNamed() {
        #expect(GamesFilmAction.addFilm.title == "Add film")
        #expect(GamesFilmAction.showUpload.title == "Show upload")
    }
}
