import Foundation
import Testing
@testable import BasketballScout

/// The film step (04 §6.1; 09 R15–R20): reading the game (and again while an analysis runs), the choices,
/// the hand-over to the app-wide upload manager, copies from Photos or a drop, the video link (04 §3) with
/// its errors and the queue outage that still saved the film (09 R19), and when the screen is finished.
@MainActor
struct NewGameFilmModelTests {
    private let gameID = "g_e934f8c21058"
    private var gamePath: String { "/api/games/\(gameID)" }
    private var linkPath: String { "/api/games/\(gameID)/video-url" }

    private struct Harness {
        let session: SessionHarness
        let uploads: UploadManager
        let games: GamesStore
        let toasts: ToastCenter
        let folder: ServiceTestFolder
        let activity: FakeUploadActivity

        var server: SessionStubServer { session.server }

        func cleanUp() {
            session.cleanUp()
            folder.remove()
        }
    }

    /// A signed-in session whose server answers `GET` of the game with `game`. Uploads go to `uploadServer`
    /// when given, else to the session's server (film by link).
    private func harness(game: String? = "game_get.json", uploadServer: FakeUploadServer? = nil) async throws -> Harness {
        let h = SessionHarness()
        try await h.signIn()
        if let game { h.server.on("GET", gamePath, .fixture(game)) }
        let folder = try ServiceTestFolder("NewGameFilm")
        let activity = FakeUploadActivity()
        let uploads = UploadManager(
            store: UploadStore(directory: folder.url.appending(path: "Store", directoryHint: .isDirectory)),
            activity: activity, sleeper: RecordingSleeper().sleeper, progressInterval: nil)
        let session = h.session
        if let uploadServer {
            let client = try uploadServer.client()
            uploads.clientProvider = { client }
        } else {
            uploads.clientProvider = { session.client }
        }
        uploads.errorReporter = { _ = session.report($0) }
        let toasts = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
        return Harness(
            session: h, uploads: uploads, games: GamesStore(session: session), toasts: toasts, folder: folder,
            activity: activity)
    }

    private func makeModel(_ h: Harness, game: Game? = nil, sleeper: Sleeper = RecordingSleeper().sleeper) -> NewGameFilmModel {
        NewGameFilmModel(
            gameID: gameID, session: h.session.session, uploads: h.uploads, games: h.games, toasts: h.toasts,
            game: game, sleeper: sleeper)
    }

    private func draftGame() throws -> Game {
        try Fixture.decode(Game.self, "game_get.json")
    }

    private func uploadState(_ model: NewGameFilmModel) -> UploadState? {
        if case .upload(let state) = model.panel { return state }
        return nil
    }

    // MARK: - Reading the game

    @Test func theGameIsReadOnceWhenNoAnalysisRuns() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h)
        #expect(!model.canChooseFilm)

        await model.run()

        #expect(h.server.count("GET", gamePath) == 1)
        #expect(model.game?.id == gameID)
        #expect(model.title == "Add film")
        #expect(model.canChooseFilm)
        #expect(model.panel == .choices)
        #expect(model.replaceNotice == nil)
        #expect(model.busyNotice == nil)
        #expect(model.pageError == nil)
    }

    @Test func aGameWithFilmIsReplaced() async throws {
        let h = try await harness(game: "game_ready.json")
        defer { h.cleanUp() }
        let model = makeModel(h)

        await model.run()

        #expect(model.title == "Replace film")
        #expect(model.replaceNotice?.title == "This game already has film")
        #expect(model.replaceNotice?.message == "New film replaces test-film.mp4 and runs the analysis again.")
        #expect(model.canChooseFilm)
    }

    @Test func whileAnAnalysisRunsTheChoicesWaitAndTheGameIsReadAgain() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("game_queued.json"), .fixture("game_processing.json"), .fixture("game_ready.json"))
        let sleeper = RecordingSleeper()
        let model = makeModel(h, sleeper: sleeper.sleeper)

        await model.run()

        #expect(h.server.count("GET", gamePath) == 3)
        #expect(sleeper.recorded == [.seconds(5), .seconds(5)])
        #expect(model.game?.status == .ready)
        #expect(model.busyNotice == nil)
        #expect(model.canChooseFilm)
    }

    @Test func aRunningAnalysisIsExplained() async throws {
        let h = try await harness(game: "game_queued.json")
        defer { h.cleanUp() }
        let blocking = BlockingSleeper()
        let model = makeModel(h, sleeper: blocking.sleeper)
        let run = Task { await model.run() }
        try await waitUntil("the first read") { model.game != nil }

        #expect(model.busyNotice?.title == "An analysis is already running")
        #expect(!model.canChooseFilm)
        #expect(model.keepsChecking)
        let film = try h.folder.makeFilm(count: 100)
        await model.chooseFile(at: film)
        #expect(h.uploads.upload(for: gameID) == nil)

        run.cancel()
        await run.value
        #expect(blocking.wasCancelled)
        #expect(h.server.count("GET", gamePath) == 1)
    }

    @Test func aMissingGameShowsOnlyThePageError() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("err_404_unknown_game.json", status: 404))
        let model = makeModel(h, game: try draftGame())

        await model.run()

        #expect(model.pageError?.title == "Not found")
        #expect(model.refreshError == nil)
        #expect(!model.canChooseFilm)
        #expect(!model.keepsChecking)
    }

    @Test func aFailedReadKeepsTheGameTheAppHas() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .html(502))
        let model = makeModel(h, game: try draftGame())

        await model.run()

        #expect(model.pageError == nil)
        #expect(model.refreshError?.title == "Server unavailable")
        #expect(model.refreshError?.isRetryable == true)
        #expect(model.canChooseFilm)
    }

    @Test func aFailedFirstReadIsAPageErrorWithTryAgain() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .html(502))
        let model = makeModel(h)

        await model.run()

        #expect(model.pageError?.isRetryable == true)
        #expect(model.game == nil)
        model.checkAgain()
        #expect(model.pollToken == 1)
    }

    @Test func aWrongPasswordStopsEverythingAndShowsNothing() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .json(401, try Fixture.data("err_401_wrong_password.json")))
        let model = makeModel(h, game: try draftGame())

        await model.run()

        #expect(model.pageError == nil)
        #expect(model.refreshError == nil)
        #expect(!h.session.session.isSignedIn)
    }

    @Test func theGameTheAppHasIsShownAtOnce() throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let uploads = UploadManager(
            store: UploadStore(directory: FileManager.default.temporaryDirectory.appending(path: "NewGameFilm-\(UUID().uuidString)")),
            activity: FakeUploadActivity())
        let seeded = try Fixture.decode(Game.self, "game_ready.json")
        let model = NewGameFilmModel(gameID: gameID, session: h.session, uploads: uploads, game: seeded)
        #expect(model.game?.status == .ready)
        // Another game's data is not taken for this one.
        let other = NewGameFilmModel(gameID: "g_5e21fcf0b398", session: h.session, uploads: uploads, game: seeded)
        #expect(other.game == nil)
        uploads.removeAll()
    }

    // MARK: - Choosing and uploading a file

    @Test func aChosenFileUploadsAndFinishesTheScreen() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        await model.chooseFile(at: try h.folder.makeFilm(count: 2500))
        try await waitUntil("the upload to finish") { model.isFinished }

        #expect(server.chunks.map(\.offset) == [0, 1000, 2000])
        #expect(uploadState(model)?.statusText == "Upload complete - opening the game\u{2026}")
        #expect(!model.canChooseFilm)
    }

    @Test func aFileThatIsNotAVideoIsRefusedAtOnce() async throws {
        let server = FakeUploadServer()
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        await model.chooseFile(at: try h.folder.makeFilm("Test Film.avi", count: 10))

        #expect(model.choiceError?.title == "Not a video file")
        #expect(model.choiceError?.message == "\"Test Film.avi\" is not an MP4, MOV or M4V video.")
        #expect(h.uploads.upload(for: gameID) == nil)
        #expect(server.steps.isEmpty)
        #expect(model.panel == .choices)
    }

    @Test func aCancelledUploadBringsTheChoicesBack() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        server.add(.hold, on: .chunk(0))
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        await model.chooseFile(at: try h.folder.makeFilm(count: 2500))
        try await waitUntil("the first chunk") { server.heldReplies.first?.isWaiting == true }
        #expect(uploadState(model)?.phase == .uploading)
        #expect(!model.canChooseFilm)

        model.cancelUpload()

        #expect(model.panel == .choices)
        #expect(model.canChooseFilm)
        try await waitUntil("the session to be deleted") { server.deletedIDs.count == 1 }
        #expect(!model.isFinished)
    }

    @Test func pauseAndResumeReachTheUpload() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        server.add(.hold, on: .chunk(0))
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        await model.chooseFile(at: try h.folder.makeFilm(count: 2500))
        try await waitUntil("the first chunk") { server.heldReplies.first?.isWaiting == true }
        model.pause()
        #expect(uploadState(model)?.phase == .paused)
        #expect(NewGameUploadControls(state: try #require(uploadState(model))).showsResume)
        try await waitUntil("the paused run to stop") { !h.activity.isRunning }

        model.resume()
        try await waitUntil("the upload to finish") { model.isFinished }
    }

    @Test func aFileRefusedBeforeAnyRequestOffersAnotherFile() async throws {
        let server = FakeUploadServer()
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        h.uploads.maxUploadBytesProvider = { 100 }
        let model = makeModel(h, game: try draftGame())

        await model.chooseFile(at: try h.folder.makeFilm(count: 500))

        let state = try #require(uploadState(model))
        #expect(state.phase.error?.title == "File too large")
        #expect(NewGameUploadControls(state: state).failureActions == [.chooseAnotherFile])
        model.perform(.chooseAnotherFile)
        #expect(model.panel == .choices)
        #expect(h.uploads.upload(for: gameID) == nil)
    }

    @Test func aFinishedUploadFromAnEarlierVisitIsClearedWhenTheScreenAppears() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let first = makeModel(h, game: try draftGame())
        await first.chooseFile(at: try h.folder.makeFilm(count: 1200))
        try await waitUntil("the upload to finish") { first.isFinished }

        let again = makeModel(h, game: try Fixture.decode(Game.self, "game_ready.json"))
        #expect(again.isFinished)
        again.appeared()

        #expect(!again.isFinished)
        #expect(again.panel == .choices)
        #expect(again.canChooseFilm)
    }

    @Test func aConflictFromTheUploadChecksTheGameAgain() throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let uploads = UploadManager(
            store: UploadStore(directory: FileManager.default.temporaryDirectory.appending(path: "NewGameFilm-\(UUID().uuidString)")),
            activity: FakeUploadActivity())
        let model = NewGameFilmModel(gameID: gameID, session: h.session, uploads: uploads)
        let conflict = APIError.server(
            ErrorInfo(code: ErrorCode.conflict, title: "Conflict", message: "This game's film is being analysed right now."),
            status: 409)

        model.uploadPhaseChanged(.failed(conflict))
        #expect(model.pollToken == 1)
        model.uploadPhaseChanged(.failed(UploadError.cannotResume))
        model.uploadPhaseChanged(.uploading)
        model.uploadPhaseChanged(nil)
        #expect(model.pollToken == 1)
        uploads.removeAll()
    }

    @Test func aPickerProblemIsShownButClosingThePickerIsNot() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        model.fileChoiceFailed(CocoaError(.userCancelled))
        #expect(model.choiceError == nil)
        model.fileChoiceFailed(CocoaError(.fileReadNoPermission))
        #expect(model.choiceError != nil)
    }

    // MARK: - Copies from Photos and drops

    @Test func aCopiedFilmIsUploaded() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        let copy = try h.folder.makeFilm("IMG_0001.MOV", count: 1200, in: "Copy")
        var deliver: NewGameFilmModel.CopyCompletion?

        model.beginImport(from: .photos) { completion in
            deliver = completion
            return Progress(totalUnitCount: 100)
        }

        guard case .importing(let job) = model.panel else {
            Issue.record("expected the copy's progress, got \(model.panel)")
            return
        }
        #expect(job.source == .photos)
        #expect(job.source.title == "Getting the film from Photos\u{2026}")
        #expect(!model.canChooseFilm)

        deliver?(.success(copy))
        try await waitUntil("the upload to finish") { model.isFinished }

        #expect(server.createBodies.count == 1)
        let created = try #require(server.createBodies.first)
        let body = try #require(try JSONSerialization.jsonObject(with: created) as? [String: Any])
        #expect(body["filename"] as? String == "IMG_0001.MOV")
        // The manager took the copy over and deleted it once the film was saved.
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    @Test func aCopyThatArrivesAfterCancelIsDeleted() async throws {
        let server = FakeUploadServer()
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        let progress = Progress(totalUnitCount: 100)
        var deliver: NewGameFilmModel.CopyCompletion?
        model.beginImport(from: .drop) { completion in
            deliver = completion
            return progress
        }

        model.cancelImport()

        #expect(progress.isCancelled)
        #expect(model.panel == .choices)
        #expect(model.canChooseFilm)
        let copy = try h.folder.makeFilm("late.mp4", count: 10, in: "Late")
        deliver?(.success(copy))
        try await waitUntil("the late copy to be deleted") { !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) }
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(h.uploads.upload(for: gameID) == nil)
        #expect(model.choiceError == nil)
        #expect(server.steps.isEmpty)
    }

    @Test func aCopyLeftBehindByAClosedScreenIsDeleted() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        var screen: NewGameFilmModel? = makeModel(h, game: try draftGame())
        var deliver: NewGameFilmModel.CopyCompletion?
        screen?.beginImport(from: .photos) { completion in
            deliver = completion
            return Progress(totalUnitCount: 1)
        }
        screen?.disappeared()
        screen = nil

        let copy = try h.folder.makeFilm("closed.mp4", count: 10, in: "Closed")
        deliver?(.success(copy))
        try await waitUntil("the copy to be deleted") { !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) }
    }

    @Test func aFailedCopyIsExplained() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        model.beginImport(from: .photos) { completion in
            completion(.failure(CocoaError(.fileReadUnknown)))
            return Progress(totalUnitCount: 1)
        }
        try await waitUntil("the copy to end") { model.importing == nil }

        #expect(model.choiceError?.title == "Couldn't get the film from Photos")
        #expect(model.choiceError?.detail != nil)
        #expect(model.panel == .choices)
    }

    @Test func aCopyWithoutAFilmIsExplained() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        model.beginImport(from: .drop) { completion in
            completion(.success(nil))
            return Progress(totalUnitCount: 1)
        }
        try await waitUntil("the copy to end") { model.importing == nil }

        #expect(model.choiceError?.title == "Couldn't copy the film")
    }

    @Test func aCancelledHandOverShowsNothing() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())

        model.beginImport(from: .photos) { completion in
            completion(.failure(CocoaError(.userCancelled)))
            return Progress(totalUnitCount: 1)
        }
        try await waitUntil("the copy to end") { model.importing == nil }

        #expect(model.choiceError == nil)
    }

    @Test func importProgressIsOnlyAFractionInBetween() {
        let progress = Progress(totalUnitCount: 10)
        #expect(NewGameFilmImport.fraction(of: progress) == nil)
        progress.completedUnitCount = 4
        #expect(NewGameFilmImport.fraction(of: progress) == 0.4)
        progress.completedUnitCount = 10
        #expect(NewGameFilmImport.fraction(of: progress) == nil)
        #expect(NewGameFilmImport.fraction(of: Progress()) == nil)
    }

    @Test func aDroppedWebLinkGoesToTheLinkField() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        let link = try #require(URL(string: "https://example.com/films/test-film.mp4"))

        #expect(model.acceptDrop([NSItemProvider(object: link as NSURL)]))

        try await waitUntil("the link in the field") { model.linkText == link.absoluteString }
        #expect(h.server.count("POST", linkPath) == 0)
    }

    @Test func dropsWaitWhileTheChoicesAreClosed() async throws {
        let h = try await harness(game: "game_queued.json")
        defer { h.cleanUp() }
        let model = makeModel(h, game: try Fixture.decode(Game.self, "game_queued.json"))
        let link = try #require(URL(string: "https://example.com/films/test-film.mp4"))

        #expect(!model.acceptDrop([NSItemProvider(object: link as NSURL)]))
        #expect(!model.acceptDrop([]))
    }

    #if os(macOS)
    @Test func aFileDroppedFromFinderIsUploadedInPlace() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        let film = try h.folder.makeFilm(count: 1500)

        #expect(model.acceptDrop([NSItemProvider(object: film as NSURL)]))

        try await waitUntil("the upload to finish") { model.isFinished }
        // A file of the coach's is read where it is, never moved or deleted.
        #expect(FileManager.default.fileExists(atPath: film.path(percentEncoded: false)))
    }
    #endif

    // MARK: - Video link (04 §3)

    @Test func aLinkThatIsNotAWebAddressIsExplainedWithoutARequest() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        model.setLinkText("example.com/films/test-film.mp4")

        await model.submitLink()

        #expect(model.linkError?.title == "Check the link")
        #expect(model.linkError?.message == "Enter the full link, including the http or https part at the start.")
        #expect(model.linkError?.hint == "It must point straight at the .mp4 file.")
        #expect(h.server.count("POST", linkPath) == 0)
        #expect(!model.isFinished)
        #expect(!model.isSavingLink)
    }

    @Test func aGoodLinkIsSentTrimmedAndFinishesTheScreen() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.server.on("POST", linkPath, .fixture("video_url_set.json"))
        let model = makeModel(h, game: try draftGame())
        model.setLinkText("  https://example.com/films/test-film.mp4 \n")

        await model.submitLink()

        #expect(model.linkError == nil)
        #expect(model.isFinished)
        #expect(!model.canChooseFilm)
        let request = try #require(h.server.requests.first { $0.method == "POST" && $0.path == linkPath })
        #expect(request.query == "auto_start=true")
        #expect(request.header("Content-Type")?.hasPrefix("application/json") == true)
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["url"] as? String == "https://example.com/films/test-film.mp4")
        // The games list has the game with its new film.
        #expect(h.games.game(id: "g_5e21fcf0b398")?.videoURL == "https://example.com/films/test-film.mp4")
        #expect(h.toasts.current == nil)
    }

    @Test func aRefusedLinkShowsTheServersText() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.server.on("POST", linkPath, .fixture("err_422_video_url_spaces.json", status: 422))
        let model = makeModel(h, game: try draftGame())
        // Passes the web's check (no whitespace) but not the server's (printable ASCII only).
        model.setLinkText("https://example.com/films/\u{E9}t\u{E9}.mp4")

        await model.submitLink()

        #expect(model.linkError?.title == "Invalid input")
        #expect(model.linkError?.message == "The video link contains spaces, line breaks or other characters a web address cannot have.")
        #expect(model.linkError?.hint == "Copy the link again from the browser's address bar (it shows a space as %20), or upload the file.")
        #expect(!model.isFinished)
        #expect(model.canChooseFilm)
    }

    @Test func aQueueOutageStillSavesTheFilmAndSaysTheAnalysisDidNotStart() async throws {
        let h = try await harness(game: nil)
        defer { h.cleanUp() }
        h.server.on("POST", linkPath, SessionFixtures.error(
            503, code: ErrorCode.queueUnavailable, title: "Job queue unavailable",
            message: "The job queue (Redis) could not be reached.", retryable: true))
        let saved = try SessionFixtures.game("game_get.json") { game in
            game.status = .uploaded
            game.videoURL = "https://example.com/films/test-film.mp4"
            game.videoFilename = "test-film.mp4"
        }
        h.server.on("GET", gamePath, try SessionFixtures.reply(saved))
        let model = makeModel(h, game: try draftGame())
        model.setLinkText("https://example.com/films/test-film.mp4")

        await model.submitLink()

        #expect(model.linkError == nil)
        #expect(model.isFinished)
        #expect(h.toasts.current?.text == "The film is saved, but the analysis did not start.")
        #expect(h.toasts.current?.tone == .danger)
        // 09 R19: the game is read again (status "uploaded": the game page offers "Analyze film").
        #expect(h.server.count("GET", gamePath) == 1)
        #expect(h.games.game(id: gameID)?.status == .uploaded)
    }

    @Test func aLinkRefusedWhileAnAnalysisRunsChecksTheGameAgain() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.server.on("POST", linkPath, .fixture("err_409_upload_while_analyzing.json", status: 409))
        let model = makeModel(h, game: try draftGame())
        model.setLinkText("https://example.com/films/test-film.mp4")

        await model.submitLink()

        #expect(model.linkError?.message == "This game's film is being analysed right now.")
        #expect(model.pollToken == 1)
        #expect(!model.isFinished)
    }

    @Test func theLinkFieldTakesAtMostTwoThousandCharacters() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        model.setLinkText("https://example.com/" + String(repeating: "a", count: 2100))
        #expect(model.linkText.count == 2000)
    }

    @Test func aLinkCannotBeSentWhileAFilmUploads() async throws {
        let server = FakeUploadServer(chunkSize: 1000)
        server.add(.hold, on: .chunk(0))
        let h = try await harness(uploadServer: server)
        defer { h.cleanUp() }
        let model = makeModel(h, game: try draftGame())
        await model.chooseFile(at: try h.folder.makeFilm(count: 2500))
        try await waitUntil("the first chunk") { server.heldReplies.first?.isWaiting == true }

        model.setLinkText("https://example.com/films/test-film.mp4")
        await model.submitLink()

        #expect(!server.steps.contains(.videoLink))
        #expect(model.linkError == nil)
        model.cancelUpload()
    }
}
