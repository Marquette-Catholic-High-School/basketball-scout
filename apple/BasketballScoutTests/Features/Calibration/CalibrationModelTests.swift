import Foundation
import Testing
@testable import BasketballScout

/// The calibration sheet against a stub server and a stub film (04 §5, §6.3; 09 R14, R37, D1 #11): opening on
/// the saved calibration, landmarks, Save, Remove, the re-run offers, errors through the lockout gate, the film
/// copy and the frame steps.
@MainActor
struct CalibrationModelTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }
    private let small = CalibrationFrameSize(width: 640, height: 360)
    private let large = CalibrationFrameSize(width: 1280, height: 720)

    /// A signed-in harness whose server knows the game and its page. `game`: the answers to `GET` the game,
    /// one per request (the last repeats); `game_with_calibration.json` when none are given.
    private func server(game replies: ServiceStubReply...) async throws -> SessionHarness {
        let h = SessionHarness()
        try await h.signIn()
        switch replies.count {
        case 0: h.server.on("GET", gamePath, .fixture("game_with_calibration.json"))
        case 1: h.server.on("GET", gamePath, replies[0])
        case 2: h.server.on("GET", gamePath, replies[0], replies[1])
        default: h.server.on("GET", gamePath, replies[0], replies[1], replies[2])
        }
        h.server.on("GET", "\(gamePath)/analysis", .fixture("analysis.json"))
        h.server.on("GET", "\(gamePath)/jobs", .fixture("jobs_list.json"))
        h.server.on("GET", "\(gamePath)/reports", .fixture("reports_list_seeded.json"))
        h.server.on("GET", "/api/court/landmarks", .fixture("court_landmarks.json"))
        return h
    }

    /// The game page's context, loaded once.
    private func loadedContext(_ h: SessionHarness, toasts: ToastCenter? = nil) async -> GameContext {
        let context = GameContext(
            gameID: gameID, session: h.session, toasts: toasts, analysisCache: h.cache,
            defaults: UserDefaults(suiteName: "CalibrationModelTests.\(UUID().uuidString)") ?? .standard,
            sleeper: RecordingSleeper().sleeper, now: h.clock.reader)
        await context.refresh()
        return context
    }

    /// The sheet opened: started, film prepared, first frame on screen.
    private func openSheet(
        _ context: GameContext, films: CalibrationStubFilms = CalibrationStubFilms(), sleeper: Sleeper = CalibrationFixtures.immediate
    ) async -> CalibrationModel {
        let model = CalibrationModel(context: context, frameSources: films.maker, sleeper: sleeper)
        await model.start()
        await model.prepareFilm()
        await model.loadRequestedFrame()
        return model
    }

    private func game(_ name: String = "game_with_calibration.json", change: (inout Game) -> Void) throws -> ServiceStubReply {
        try SessionFixtures.reply(try SessionFixtures.game(name, change: change))
    }

    /// Four corners of the court on a 1280×720 frame.
    private func placeFourCorners(_ model: CalibrationModel) {
        for (name, x, y) in [
            ("left_baseline_near_corner", 80.0, 660.0), ("left_baseline_far_corner", 300.0, 240.0),
            ("right_baseline_near_corner", 1200.0, 660.0), ("right_baseline_far_corner", 980.0, 240.0),
        ] {
            model.select(name)
            model.tap(atPixel: XY(x: x, y: y))
        }
    }

    // MARK: - Opening

    @Test func openingShowsTheSavedCalibrationAndItsFit() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        let context = await loadedContext(h)
        let films = CalibrationStubFilms()
        let model = await openSheet(context, films: films)

        let saved = try #require(context.game?.calibration)
        #expect(model.savedCalibration == saved)
        #expect(model.landmarks?.landmarks.count == 25)
        #expect(model.variant == .original)
        #expect(model.frame?.size == small)
        // No size saved: the points are in the pixels of the copy on screen (calibrate.js:125-127).
        #expect(model.points == saved.points)
        #expect(model.fitCalibration == saved)
        #expect(model.projectedLines.count == 18)
        #expect(model.countText == "4 points - ready to save (more points spread over the court make it more accurate).")
        #expect(model.tip == CalibrationText.fewPointsTip)
        #expect(!model.hasUnsavedChanges && model.canSave)
        #expect(!model.offersFullReanalysis)
        #expect(model.rerunTitle == "Re-run analysis")
        // The game is read again when the sheet opens (09 R37).
        #expect(h.server.count("GET", gamePath) == 2)
        #expect(films.made.map(\.variant) == [.original])
        #expect(films.made.first?.requestedTimes == [0])
    }

    @Test func theFilmOpensOnTheSavedFrameInTheCopysPixels() async throws {
        let put = try CalibrationFixtures.calibration()  // frame_t 1.5, 640×360
        let h = try await server(game: try game { $0.calibration = put })
        defer { h.cleanUp() }
        let films = CalibrationStubFilms(sizes: [.original: large])
        let model = await openSheet(await loadedContext(h), films: films)

        #expect(films.made.first?.requestedTimes == [1.5])
        #expect(model.frame?.time == 1.5)
        #expect(model.points[0].px == XY(x: 80, y: 660))
        #expect(model.fitCalibration == put)
        #expect(!model.canGoToSavedFrame)

        model.step(seconds: 5)
        #expect(model.frameRequest?.time == 6.5)
        await model.loadRequestedFrame()
        #expect(model.canGoToSavedFrame)
        model.goToSavedFrame()
        #expect(model.frameRequest?.time == 1.5)
    }

    @Test func withoutASavedFrameTheFilmOpensWhereThePlayerIs() async throws {
        let h = try await server(game: .fixture("game_without_calibration.json"))
        defer { h.cleanUp() }
        let context = await loadedContext(h)
        context.playback.currentTime = 42
        let films = CalibrationStubFilms()
        let model = await openSheet(context, films: films)
        #expect(films.made.first?.requestedTimes == [42])
        #expect(model.frame?.time == 42)
        #expect(model.points.isEmpty)
        #expect(model.fitCalibration == nil)
        #expect(model.selectedLandmark == "left_baseline_near_corner")
    }

    @Test func landmarksAreLoadedWhenThePageHasNone() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        let failure = SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true)
        h.server.on("GET", "/api/court/landmarks", failure, failure, .fixture("court_landmarks.json"))
        let context = await loadedContext(h)
        #expect(context.landmarks == nil)

        let model = await openSheet(context)
        #expect(h.server.count("GET", "/api/court/landmarks") == 3)
        #expect(model.landmarks != nil)
        #expect(model.draft?.points == context.game?.calibration?.points)
        #expect(h.session.courtLandmarks != nil)
    }

    @Test func landmarksThatCannotBeLoadedAreExplained() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        h.server.on("GET", "/api/court/landmarks", SessionFixtures.error(
            500, code: "INTERNAL_ERROR", title: "Unexpected error", message: "Something went wrong on the server.", retryable: true))
        let model = await openSheet(await loadedContext(h))
        #expect(model.draft == nil)
        #expect(model.landmarksError?.title == "Unexpected error")
        #expect(model.landmarksError?.isRetryable == true)
    }

    // MARK: - Saving

    @Test func saveSendsThePointsInThePixelsOfTheCopyShown() async throws {
        let h = try await server(game: .fixture("game_without_calibration.json"))
        defer { h.cleanUp() }
        let model = await openSheet(await loadedContext(h), films: CalibrationStubFilms(sizes: [.original: large]))
        placeFourCorners(model)
        #expect(model.canSave && model.hasUnsavedChanges)
        let response = try CalibrationFixtures.calibration("calibration_put_minimal.json")
        h.server.on("PUT", "\(gamePath)/calibration", .fixture("calibration_put_minimal.json"))

        await model.save()

        let put = try #require(h.server.requests.last { $0.method == "PUT" })
        #expect(put.path == "\(gamePath)/calibration")
        #expect(put.header("Content-Type")?.hasPrefix("application/json") == true)
        #expect(put.header("Authorization")?.hasPrefix("Basic ") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: put.body) as? [String: Any])
        #expect(body["video_width"] as? Int == 1280)
        #expect(body["video_height"] as? Int == 720)
        #expect(body["frame_t"] as? Double == 0)
        let points = try #require(body["points"] as? [[String: Any]])
        #expect(points.map { $0["landmark"] as? String } == [
            "left_baseline_near_corner", "left_baseline_far_corner", "right_baseline_near_corner", "right_baseline_far_corner",
        ])
        #expect(points.first?["px"] as? [Double] == [80, 660])

        #expect(model.savedCalibration == response)
        #expect(!model.hasUnsavedChanges)
        #expect(model.fitCalibration == response)
        #expect(model.announcesFit)
        #expect(model.outcome == nil)
        #expect(!model.isSaving)
        // The page's game takes the answer (its other parts see the calibration) without reloading the page.
        #expect(h.server.count("GET", gamePath) == 2)
        #expect(model.context.game?.calibration == response)
    }

    @Test func fewerThanFourPointsAreNotSent() async throws {
        let h = try await server(game: .fixture("game_without_calibration.json"))
        defer { h.cleanUp() }
        let model = await openSheet(await loadedContext(h))
        model.tap(atPixel: XY(x: 10, y: 10))
        #expect(!model.canSave)
        await model.save()
        #expect(h.server.count("PUT", "\(gamePath)/calibration") == 0)
    }

    @Test func aRejectedSaveShowsTheServersExplanation() async throws {
        let h = try await server(game: .fixture("game_without_calibration.json"))
        defer { h.cleanUp() }
        let model = await openSheet(await loadedContext(h), films: CalibrationStubFilms(sizes: [.original: large]))
        placeFourCorners(model)
        h.server.on("PUT", "\(gamePath)/calibration", .fixture("err_422_calibration_collinear.json", status: 422))

        await model.save()

        guard case .saveFailed(let error)? = model.outcome else {
            Issue.record("expected the save error")
            return
        }
        #expect(error.title == "Court calibration rejected")
        #expect(error.message == "The clicked court points do not produce a usable mapping.")
        #expect(error.hint == "Click at least 4 landmarks spread across the court, not all on one line.")
        #expect(error.detail == "points are degenerate (collinear or duplicated)")
        #expect(!error.isRetryable)
        #expect(model.points.count == 4 && model.hasUnsavedChanges)
        #expect(model.savedCalibration == nil)
        #expect(!model.isSaving)
    }

    @Test func aSaveTurnedAwayByTheLockoutGateShowsNothing() async throws {
        let h = try await server(game: .fixture("game_without_calibration.json"))
        defer { h.cleanUp() }
        let model = await openSheet(await loadedContext(h), films: CalibrationStubFilms(sizes: [.original: large]))
        placeFourCorners(model)
        h.server.on("PUT", "\(gamePath)/calibration", .fixture("err_401_wrong_password.json", status: 401))

        await model.save()

        #expect(model.outcome == nil)
        guard case .needsPassword = h.session.state else {
            Issue.record("the 401 should stop everything (09 R6)")
            return
        }
    }

    // MARK: - Removing

    @Test func removingAsksFirstThenDeletesAndSaysWhatHappensNext() async throws {
        let h = try await server(game: .fixture("game_with_calibration.json"))
        defer { h.cleanUp() }
        h.server.on("DELETE", "\(gamePath)/calibration", .empty(204))
        let context = await loadedContext(h)
        let model = await openSheet(context)
        #expect(model.hasSavedCalibration)
        let loads = h.server.count("GET", gamePath)

        model.requestRemoveSaved()
        let question = try #require(model.confirmation)
        #expect(question.title == "Remove the saved court calibration for this game?")
        #expect(question.confirmTitle == "Remove")
        #expect(question.isDestructive)
        #expect(h.server.count("DELETE", "\(gamePath)/calibration") == 0)

        await model.removeSaved()

        #expect(h.server.count("DELETE", "\(gamePath)/calibration") == 1)
        guard case .removed(let text)? = model.outcome else {
            Issue.record("expected the removal notice")
            return
        }
        #expect(text == "Calibration removed. Re-run the analysis to go back to automatic court detection.")
        #expect(model.points.isEmpty && !model.hasSavedCalibration && !model.canUndo)
        // The page's game drops the calibration as answered, without reloading the page (game.js `onChange`).
        #expect(context.game?.calibration == nil)
        #expect(h.server.count("GET", gamePath) == loads)
        model.syncWithContext()
        #expect(model.points.isEmpty)
    }

    @Test func withoutGPUResultsTheRemovalNoticeAndRerunSayAnalyze() async throws {
        let h = try await server(game: try game { $0.hasTracking = false })
        defer { h.cleanUp() }
        h.server.on("DELETE", "\(gamePath)/calibration", .empty(204))
        let model = await openSheet(await loadedContext(h))
        #expect(model.rerunTitle == "Analyze film")
        await model.removeSaved()
        guard case .removed(let text)? = model.outcome else {
            Issue.record("expected the removal notice")
            return
        }
        #expect(text == "Calibration removed. The analysis will use automatic court detection.")
    }

    // MARK: - Re-running

    @Test func theRerunStartsTheGamesRerunKindAndCloses() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        let toasts = CalibrationFixtures.toasts()
        let model = await openSheet(await loadedContext(h, toasts: toasts))
        #expect(!model.jobsBlocked)

        await model.startRerun()

        let post = try #require(h.server.requests.last { $0.method == "POST" && $0.path == "\(gamePath)/jobs" })
        #expect(post.bodyText == #"{"kind":"reanalyze"}"#)
        #expect(toasts.current?.text == "Re-running the analysis\u{2026}")
        #expect(model.shouldDismiss)
        #expect(model.jobError == nil)
        #expect(model.startingJob == nil)
    }

    @Test func withoutGPUResultsTheRerunAnalyzesTheFilm() async throws {
        let h = try await server(game: try game { $0.hasTracking = false })
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_analyze_full.json", status: 201))
        let toasts = CalibrationFixtures.toasts()
        let model = await openSheet(await loadedContext(h, toasts: toasts))

        await model.startRerun()

        let post = try #require(h.server.requests.last { $0.method == "POST" && $0.path == "\(gamePath)/jobs" })
        #expect(post.bodyText == #"{"kind":"analyze"}"#)
        #expect(toasts.current?.text == "Analysis started")
    }

    @Test func aFullReanalysisIsOfferedWhenFreeThrowsWereMissedAndAsksFirst() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        var analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        analysis.dataQuality.warnings.append(PipelineWarning(
            code: PipelineWarning.freeThrowsNotDetectedCode, message: "No free throws were detected.", severity: .warning))
        h.server.on("GET", "\(gamePath)/analysis", try SessionFixtures.reply(analysis))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_analyze_full.json", status: 201))
        let toasts = CalibrationFixtures.toasts()
        let model = await openSheet(await loadedContext(h, toasts: toasts))

        #expect(model.offersFullReanalysis)
        #expect(model.resultHint.hasSuffix("Free throws need a full re-analysis: it sends the film to the GPU again."))
        model.requestFullReanalysis()
        let question = try #require(model.confirmation)
        let expected = Game.fullReanalysisConfirmation(showsResults: true)
        #expect(question.title == expected.title)
        #expect(question.message == expected.message)
        #expect(question.confirmTitle == "Send to GPU")
        #expect(!question.isDestructive)
        #expect(h.server.count("POST", "\(gamePath)/jobs") == 0)

        await model.startFullReanalysis()

        let post = try #require(h.server.requests.last { $0.method == "POST" && $0.path == "\(gamePath)/jobs" })
        #expect(post.bodyText == #"{"kind":"analyze"}"#)
        #expect(toasts.current?.text == "Full re-analysis started")
        #expect(model.shouldDismiss)
    }

    @Test func theResultsButtonsWaitWhileAnAnalysisRuns() async throws {
        let h = try await server(game: .fixture("game_queued.json"))
        defer { h.cleanUp() }
        let model = await openSheet(await loadedContext(h))
        #expect(model.jobsBlocked)
        #expect(model.rerunHelp == "An analysis is already running")
        await model.startRerun()
        await model.startFullReanalysis()
        #expect(h.server.count("POST", "\(gamePath)/jobs") == 0)
        #expect(!model.shouldDismiss)
    }

    @Test func aJobThatCannotStartIsExplainedInTheSheet() async throws {
        let h = try await server()
        defer { h.cleanUp() }
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        let model = await openSheet(await loadedContext(h))

        await model.startRerun()

        #expect(model.jobError?.title == "Conflict")
        #expect(model.jobError?.message == "This game's film is being analysed right now.")
        #expect(!model.shouldDismiss)
        #expect(model.startingJob == nil)
    }

    // MARK: - Another device

    @Test func aCalibrationSavedElsewhereIsShownWhenNothingWasEdited() async throws {
        let put = try CalibrationFixtures.calibration()
        let h = try await server(
            game: .fixture("game_without_calibration.json"), .fixture("game_without_calibration.json"),
            try game("game_without_calibration.json") { $0.calibration = put })
        defer { h.cleanUp() }
        let context = await loadedContext(h)
        let model = await openSheet(context)
        #expect(model.points.isEmpty)

        await context.refresh()
        model.syncWithContext()

        #expect(model.savedCalibration == put)
        #expect(model.points == put.points)
        #expect(model.fitCalibration == put)
    }

    @Test func aCalibrationSavedElsewhereKeepsThePointsBeingPlaced() async throws {
        let put = try CalibrationFixtures.calibration()
        let h = try await server(
            game: .fixture("game_without_calibration.json"), .fixture("game_without_calibration.json"),
            try game("game_without_calibration.json") { $0.calibration = put })
        defer { h.cleanUp() }
        let context = await loadedContext(h)
        let model = await openSheet(context)
        model.tap(atPixel: XY(x: 40, y: 330))

        await context.refresh()
        model.syncWithContext()

        #expect(model.savedCalibration == put)
        #expect(model.points.count == 1)
        #expect(model.hasUnsavedChanges)
        #expect(model.hasSavedCalibration)
    }

    // MARK: - Film copy (sample data, no server)

    @Test func anUnreadableOriginalFallsBackToTheAnnotatedCopy() async throws {
        let game = CalibrationPreviewData.game(hasAnnotatedVideo: true)
        let context = GameContext.preview(game: game, landmarks: try CalibrationFixtures.landmarks())
        let films = CalibrationStubFilms(sizes: [.original: CalibrationFrameSize(width: 1920, height: 1080), .annotated: large])
        films.frameFailures[.original] = .unreadable
        let model = await openSheet(context, films: films)
        #expect(model.filmAttempt == 1)
        #expect(model.filmNotice == CalibrationText.annotatedFallback)

        await model.prepareFilm()
        await model.loadRequestedFrame()

        #expect(films.made.map(\.variant) == [.original, .annotated])
        #expect(model.variant == .annotated)
        #expect(model.frame?.size == large)
        #expect(films.made.last?.requestedTimes == [1.5])
        // Saved on 640×360: shown in the annotated copy's pixels.
        #expect(model.points[0].px == XY(x: 80, y: 660))
        #expect(model.fitCalibration != nil)
        #expect(model.filmError == nil)
    }

    @Test func aFilmRequestErrorIsShownWithTryAgain() async throws {
        let info = try Fixture.decode(ErrorEnvelope.self, "err_404_video_none.json").error
        let context = GameContext.preview(game: CalibrationPreviewData.game(), landmarks: try CalibrationFixtures.landmarks())
        let films = CalibrationStubFilms()
        films.infoFailures[.original] = .request(.server(info, status: 404))
        let model = await openSheet(context, films: films)
        #expect(model.filmError?.title == "Not found")
        #expect(model.filmError?.message == "No film has been uploaded for this game yet.")
        #expect(model.frame == nil)

        films.infoFailures[.original] = nil
        model.retryFilm()
        #expect(model.filmError == nil)
        await model.prepareFilm()
        await model.loadRequestedFrame()
        #expect(model.frame != nil)
    }

    @Test func aLockoutFromTheFilmLoaderIsLeftToTheGate() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(), landmarks: try CalibrationFixtures.landmarks())
        let films = CalibrationStubFilms()
        films.frameFailures[.original] = .request(.unauthorized(nil))
        let model = await openSheet(context, films: films)
        #expect(model.filmError == nil)
        #expect(model.frame == nil)
    }

    @Test func aFilmThatCannotBeDecodedIsExplained() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(), landmarks: try CalibrationFixtures.landmarks())
        let films = CalibrationStubFilms()
        films.frameFailures[.original] = .unreadable
        let model = await openSheet(context, films: films)
        #expect(model.filmError?.title == CalibrationText.unreadableTitle)
        #expect(model.filmError?.isRetryable == true)
    }

    @Test func gamesWithoutFilmHaveNothingToCalibrate() throws {
        let landmarks = try CalibrationFixtures.landmarks()
        let draft = CalibrationModel(
            context: GameContext.preview(game: try Fixture.decode(Game.self, "game_get.json"), landmarks: landmarks))
        #expect(draft.unavailableMessage == "Add film to this game before calibrating the court.")
        let link = CalibrationModel(
            context: GameContext.preview(game: try Fixture.decode(Game.self, "game_link_ready.json"), landmarks: landmarks))
        #expect(link.unavailableMessage == CalibrationText.linkFilmWithoutCopy)
        let calibrated = CalibrationModel(context: GameContext.preview(game: CalibrationPreviewData.game(), landmarks: landmarks))
        #expect(calibrated.unavailableMessage == nil)
    }

    @Test func aLinkFilmIsCalibratedOnTheAnnotatedCopy() async throws {
        let game = CalibrationPreviewData.game(
            calibration: nil, hasVideo: false, hasAnnotatedVideo: true, videoURL: "https://example.com/films/test-film.mp4")
        let films = CalibrationStubFilms()
        let model = await openSheet(GameContext.preview(game: game, landmarks: try CalibrationFixtures.landmarks()), films: films)
        #expect(films.made.map(\.variant) == [.annotated])
        #expect(model.filmNotice == CalibrationText.linkFilmCopy)
        #expect(model.frame?.size == large)
    }

    // MARK: - Frames and points

    @Test func scrubbingWaitsForTheSliderToRest() async throws {
        let recorder = RecordingSleeper()
        let context = GameContext.preview(game: CalibrationPreviewData.game(), landmarks: try CalibrationFixtures.landmarks())
        let model = await openSheet(context, sleeper: recorder.sleeper)
        #expect(recorder.recorded.isEmpty)

        model.scrub(to: 10)
        #expect(model.frameRequest?.debounce == true)
        await model.loadRequestedFrame()

        #expect(recorder.recorded == [CalibrationModel.scrubDelay])
        #expect(model.frame?.time == 10)
        #expect(model.displayTime == 10)
    }

    @Test func stepsMoveFromTheFrameOnScreen() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(calibration: nil), landmarks: try CalibrationFixtures.landmarks())
        let model = await openSheet(context)
        #expect(model.frame?.time == 0)

        model.stepFrames(1)
        #expect(abs((model.frameRequest?.time ?? 0) - 1.5 / 30) < 1e-12)
        await model.loadRequestedFrame()
        #expect(abs((model.frame?.time ?? 0) - 1.0 / 30) < 1e-12)

        model.stepFrames(-1)
        await model.loadRequestedFrame()
        #expect(model.frame?.time == 0)

        model.step(seconds: 5)
        await model.loadRequestedFrame()
        #expect(abs((model.frame?.time ?? 0) - 5) < 1e-9)

        model.step(seconds: 1_000)
        #expect(abs((model.frameRequest?.time ?? 0) - (120 - 1.0 / 60)) < 1e-9)
        model.step(seconds: -10_000)
        #expect(model.frameRequest?.time == 0)
    }

    @Test func clicksOutsideThePictureAreExplained() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(calibration: nil), landmarks: try CalibrationFixtures.landmarks())
        let model = await openSheet(context)
        model.tap(atPixel: nil)
        #expect(model.messages.current?.text == CalibrationText.outsidePicture)
        #expect(model.points.isEmpty)
    }

    @Test func thePickerGroupsTheLandmarksAndNumbersPlacedOnes() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(calibration: nil), landmarks: try CalibrationFixtures.landmarks())
        let model = await openSheet(context)
        #expect(model.landmarkSections.map(\.group) == [.leftEnd, .rightEnd, .middle])
        #expect(model.landmarkSections.map(\.landmarks.count) == [10, 10, 5])
        #expect(model.landmarkSections.first?.group.title == "Left end (as the camera sees it)")

        model.select("left_ft_circle_top")
        model.tap(atPixel: XY(x: 200, y: 200))
        let circleTop = try #require(model.landmarks?["left_ft_circle_top"])
        #expect(model.optionTitle(for: circleTop) == "Left end: top of the free-throw circle (point 1)")
        model.select("left_three_top")
        #expect(model.selectedSameSpotNote
            == "Same spot on this court as Left end: top of the free-throw circle (point 1). Place only one of them.")
        #expect(model.placementCount == 1)
    }

    @Test func undoClearAndRemoveWorkOnThePoints() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(calibration: nil), landmarks: try CalibrationFixtures.landmarks())
        let model = await openSheet(context)
        model.tap(atPixel: XY(x: 10, y: 10))
        model.tap(atPixel: XY(x: 20, y: 20))
        #expect(model.points.count == 2 && model.canUndo && model.canClear)
        model.select("left_baseline_near_corner")
        model.removeSelectedPoint()
        #expect(model.points.map(\.landmark) == ["left_baseline_far_corner"])
        model.undo()
        #expect(model.points.count == 2)
        model.clear()
        #expect(model.points.isEmpty && !model.canClear)
    }

    @Test func closingWithUnsavedPointsAsksFirst() async throws {
        let context = GameContext.preview(game: CalibrationPreviewData.game(calibration: nil), landmarks: try CalibrationFixtures.landmarks())
        let untouched = await openSheet(context)
        untouched.requestClose()
        #expect(untouched.shouldDismiss && untouched.confirmation == nil)

        let edited = await openSheet(context)
        edited.tap(atPixel: XY(x: 10, y: 10))
        edited.requestClose()
        #expect(!edited.shouldDismiss)
        let question = try #require(edited.confirmation)
        #expect(question.title == "Close without saving?")
        #expect(question.confirmTitle == "Discard changes")
        #expect(question.cancelTitle == "Keep editing")
        #expect(question.isDestructive)
        question.action()
        #expect(edited.shouldDismiss)
    }
}
