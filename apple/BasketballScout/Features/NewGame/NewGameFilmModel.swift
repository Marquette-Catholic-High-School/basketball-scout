import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

/// Step 2, "Game film" (04 §6.1; upload.js:109-456), for one game: what the film screen shows and does.
///
/// - The game is read when the screen opens (the web's `GET /api/games/<id>`), and every 5 seconds while
///   an analysis is queued or running: the server refuses new film then (409 `CONFLICT`), so the choices
///   wait with a notice instead of letting the coach copy a film that would be refused.
/// - A film from Files or Finder is uploaded in place (`FilmSource.external`); a film from Photos or a drop
///   that hands over data is first copied into the app (`NewGameCopiedFilm`, with progress and Cancel),
///   then uploaded as `.copied`. The upload itself belongs to the app-wide `UploadManager`, so it carries on
///   when this screen goes away.
/// - "Use a video link" (04 §3): `UploadManager.submitVideoLink`. A 503 `QUEUE_UNAVAILABLE` there still
///   saved the film (09 R19): the screen finishes with the toast "The film is saved, but the analysis did
///   not start." and the game is read again.
/// - `isFinished` turns true when the film is saved (upload complete or link saved); the view then calls
///   its `onFinished`.
///
/// Every API error goes through `ServerSession.report(_:from:)` (lockout gate) before it is shown.
@Observable
final class NewGameFilmModel {
    /// What the card shows under its notices.
    enum Panel: Equatable {
        /// The drop zone, "or" and the video link form.
        case choices
        /// A film being copied in before its upload starts.
        case importing(NewGameFilmImport)
        /// The game's upload, in any phase but cancelled.
        case upload(UploadState)
    }

    let gameID: String
    /// The game (seeded from the game page or the games list, then read from the server).
    private(set) var game: Game?
    /// The game could not be shown at all (gone, or never loaded): the page shows only this.
    private(set) var pageError: (any PresentableError)?
    /// A later read failed; the screen keeps working with the game it has.
    private(set) var refreshError: (any PresentableError)?
    /// A film being copied in (Photos, drop).
    private(set) var importing: NewGameFilmImport?
    /// A film that was refused before any upload (not a video, Photos could not hand it over).
    private(set) var choiceError: (any PresentableError)?
    /// The "Video link" field.
    private(set) var linkText = ""
    private(set) var linkError: (any PresentableError)?
    private(set) var isSavingLink = false
    private(set) var linkSaved = false
    /// Restarts `run()` (the view's task id): "Try again", "Check again", or a refusal that suggests an
    /// analysis started meanwhile.
    private(set) var pollToken = 0

    @ObservationIgnored let session: ServerSession
    @ObservationIgnored let uploads: UploadManager
    @ObservationIgnored let games: GamesStore?
    @ObservationIgnored let toasts: ToastCenter?
    @ObservationIgnored private let sleeper: Sleeper

    /// How often the game is read while an analysis runs (the games list's rate, 07 §6).
    static let busyCheckInterval: Duration = .seconds(5)

    /// - Parameters:
    ///   - game: the game as the app already has it (shown at once).
    ///   - sleeper: the wait between reads while an analysis runs (tests pass one that returns at once).
    init(
        gameID: String,
        session: ServerSession,
        uploads: UploadManager,
        games: GamesStore? = nil,
        toasts: ToastCenter? = nil,
        game: Game? = nil,
        sleeper: Sleeper = .live
    ) {
        self.gameID = gameID
        self.session = session
        self.uploads = uploads
        self.games = games
        self.toasts = toasts
        self.game = game?.id == gameID ? game : nil
        self.sleeper = sleeper
    }

    // MARK: - What the screen shows

    /// "Add film", or "Replace film" when the game has film (04 §6.1).
    var title: String {
        game?.filmButtonTitle ?? NewGameCopy.addFilmTitle
    }

    /// The game's upload; a cancelled one counts as none (the choices come back, upload.js:365-385).
    var upload: UploadState? {
        guard let state = uploads.upload(for: gameID), state.phase != .cancelled else { return nil }
        return state
    }

    var panel: Panel {
        if let importing { return .importing(importing) }
        if let upload { return .upload(upload) }
        return .choices
    }

    /// A film or link can be chosen now: the game is known, no analysis runs, it is not live, nothing else is
    /// under way.
    var canChooseFilm: Bool {
        guard let game, pageError == nil else { return false }
        return !game.isBusy && !game.isLive && importing == nil && !isSavingLink && !linkSaved && upload == nil
    }

    /// "Live stream" is offered (docs/LIVE.md): the game has no film and is not live already.
    var offersLiveStream: Bool {
        game?.canGoLive == true && canChooseFilm
    }

    /// The film is saved: the upload is complete, or the link was taken.
    var isFinished: Bool {
        linkSaved || uploads.upload(for: gameID)?.phase == .finished
    }

    /// "This game already has film" (04 §6.1, §2.9).
    var replaceNotice: NoticeText? {
        guard !linkSaved, let game else { return nil }
        return NewGameCopy.replaceFilmNotice(for: game)
    }

    /// An analysis is queued or running: new film has to wait.
    var busyNotice: NoticeText? {
        guard !linkSaved, game?.isBusy == true, game?.isLive != true else { return nil }
        return NewGameCopy.analysisRunningNotice
    }

    /// The game is live: its film arrives from the stream, and the server takes no other film meanwhile.
    var liveNotice: NoticeText? {
        game?.isLive == true ? NewGameCopy.liveGameNotice : nil
    }

    /// An upload found after a relaunch that is not running.
    var interruptedNotice: NoticeText? {
        guard let upload, upload.phase == .paused, upload.pauseReason == .interrupted else { return nil }
        return NewGameCopy.interruptedNotice(fileName: upload.fileName)
    }

    // MARK: - Loading

    /// The screen's life (run it with `.taskWhileActive(id: pollToken)`): reads the game, then again every
    /// 5 seconds while an analysis runs, until the screen goes away or the app leaves the foreground.
    func run() async {
        await Repeating.every(Self.busyCheckInterval, sleeper: sleeper) { [weak self] in
            guard let self else { return false }
            await self.reload()
            return self.keepsChecking
        }
    }

    /// Read the game again while an analysis runs or the game is live (and nothing stopped the screen).
    var keepsChecking: Bool {
        (game?.isBusy == true || game?.isLive == true) && pageError == nil && session.isSignedIn
    }

    /// `GET /api/games/{id}`.
    func reload() async {
        guard let client = session.client else { return }
        do {
            let loaded = try await client.game(id: gameID)
            game = loaded
            pageError = nil
            refreshError = nil
            session.markReachable()
        } catch {
            guard !error.isCancellation, let shown = session.report(error, from: client) else { return }
            if error.isNotFound || game == nil {
                pageError = shown
            } else {
                refreshError = shown
            }
        }
    }

    /// "Try again" / "Check again": reads the game now (and keeps checking while an analysis runs).
    func checkAgain() {
        pollToken += 1
    }

    /// The screen appeared: an upload of this game that finished (or was cancelled) on an earlier visit is
    /// over, so the choices are offered for new film.
    func appeared() {
        if let state = uploads.upload(for: gameID), state.phase == .finished || state.phase == .cancelled {
            uploads.dismiss(gameID: gameID)
        }
    }

    /// The screen went away: a copy in progress is stopped (the upload itself carries on).
    func disappeared() {
        cancelImport()
    }

    // MARK: - Choosing a film

    /// A film from Files, Finder or a Finder drop: uploaded in place. A name that is not .mp4, .mov or .m4v
    /// is refused at once, without an upload (upload.js:136-152).
    func chooseFile(at url: URL) async {
        choiceError = nil
        guard canChooseFilm else { return }
        let name = url.lastPathComponent
        guard UploadInit(filename: name, size: 1).hasAllowedExtension else {
            choiceError = UploadError.notAVideo(fileName: name)
            return
        }
        await startUpload(.external(url))
    }

    /// The file picker failed (not when the coach closed it).
    func fileChoiceFailed(_ error: any Error) {
        guard !Self.isCancellation(error) else { return }
        choiceError = DisplayError.describing(error)
    }

    /// Hands back the copy's URL (or nil: no film among the item's types), or an error; called once, on any thread.
    typealias CopyCompletion = @Sendable (Result<URL?, any Error>) -> Void

    /// Copies a film in (Photos, a drop) and uploads the copy. `load` starts the system's hand-over and
    /// returns its progress; cancelling that progress (`cancelImport()`) stops it. A copy that arrives
    /// after a cancel, or after the screen went away, is deleted.
    func beginImport(from source: NewGameFilmImport.Source, load: (_ completion: @escaping CopyCompletion) -> Progress) {
        guard canChooseFilm else { return }
        choiceError = nil
        let (results, continuation) = AsyncStream.makeStream(
            of: Result<URL?, any Error>.self, bufferingPolicy: .bufferingNewest(1))
        let progress = load { result in
            continuation.yield(result)
            continuation.finish()
        }
        let job = NewGameFilmImport(source: source, progress: progress)
        importing = job
        Task { [weak self] in
            var outcome: Result<URL?, any Error> = .failure(CancellationError())
            for await result in results { outcome = result }
            if let self {
                await self.importEnded(job, outcome: outcome)
            } else if case .success(let url?) = outcome {
                NewGameCopiedFilm.discard(url)
            }
        }
    }

    /// Stops the copy in progress.
    func cancelImport() {
        guard let job = importing else { return }
        importing = nil
        job.progress.cancel()
    }

    private func importEnded(_ job: NewGameFilmImport, outcome: Result<URL?, any Error>) async {
        let isCurrent = importing?.id == job.id
        if isCurrent { importing = nil }
        switch outcome {
        case .success(let url?):
            guard isCurrent else {
                NewGameCopiedFilm.discard(url)
                return
            }
            await startUpload(.copied(url))
        case .success(nil):
            if isCurrent { choiceError = NewGameCopy.copyFailed(fromPhotos: job.source == .photos, detail: nil) }
        case .failure(let error):
            guard isCurrent, !Self.isCancellation(error) else { return }
            choiceError = NewGameCopy.copyFailed(fromPhotos: job.source == .photos, detail: error.localizedDescription)
        }
    }

    /// Something dropped on the drop zone (the first item counts, like the web): a Finder file on the Mac
    /// (uploaded in place), a film handed over as data (copied), or a web link (put in the link field).
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canChooseFilm, let provider = providers.first else { return false }
        #if os(macOS)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [self] url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in await self.chooseFile(at: url) }
            }
            return true
        }
        #endif
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            beginImport(from: .drop) { completion in
                provider.loadTransferable(type: NewGameCopiedFilm.self) { result in
                    completion(result.map { Optional($0.url) })
                }
            }
            return true
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [self] url, _ in
                guard let url, Self.isWebLink(url) else { return }
                let text = url.absoluteString
                Task { @MainActor in self.setLinkText(text) }
            }
            return true
        }
        return false
    }

    /// Starts the upload, unless one of this game is already running (upload.js:182: a film chosen then
    /// is ignored; its copy is deleted).
    private func startUpload(_ film: FilmSource) async {
        guard uploads.upload(for: gameID)?.isActive != true else {
            if case .copied(let url) = film { NewGameCopiedFilm.discard(url) }
            return
        }
        await uploads.start(gameID: gameID, film: film)
    }

    // MARK: - The upload

    func pause() {
        uploads.pause(gameID: gameID)
    }

    func resume() {
        uploads.resume(gameID: gameID)
    }

    /// After the coach confirmed "Cancel this upload? …": the session is deleted, the choices come back.
    func cancelUpload() {
        uploads.cancel(gameID: gameID)
    }

    /// A button of the failure's error box.
    func perform(_ action: NewGameUploadControls.FailureAction) {
        switch action {
        case .resumeUpload:
            uploads.resume(gameID: gameID)
        case .uploadAgain:
            uploads.restart(gameID: gameID)
        case .chooseAnotherFile:
            choiceError = nil
            uploads.dismiss(gameID: gameID)
        }
    }

    /// Follows the upload: a refusal because an analysis runs (409 `CONFLICT`) reads the game again, so the
    /// screen says so.
    func uploadPhaseChanged(_ phase: UploadPhase?) {
        guard let error = phase?.error, Self.isConflict(error) else { return }
        checkAgain()
    }

    // MARK: - Video link (04 §3, §6.1)

    /// Sets the "Video link" field (at most 2000 characters, the server's limit).
    func setLinkText(_ text: String) {
        linkText = NewGameTextLimit.clamp(text, maxCodePoints: NewGameTextLimit.videoLink)
    }

    /// "Use this link" ("Saving…"): the web's check, then `POST …/video-url?auto_start=true` with only the link.
    func submitLink() async {
        guard !isSavingLink, canChooseFilm else { return }
        linkError = nil
        isSavingLink = true
        defer { isSavingLink = false }
        let client = session.client
        do {
            let completion = try await uploads.submitVideoLink(linkText, gameID: gameID)
            if let saved = completion.game { games?.upsert(saved) }
            if completion.filmSavedWithoutAnalysis {
                // 09 R19: the film IS saved; the game page offers "Analyze film".
                toasts?.show(NewGameCopy.filmSavedWithoutAnalysis, tone: .danger)
                await rereadGame()
            }
            linkSaved = true
        } catch {
            if Self.isConflict(error) { checkAgain() }
            linkError = session.report(error, from: client)
        }
    }

    /// Reads the game after a film change whose answer had no game, for the games list.
    private func rereadGame() async {
        guard let client = session.client else { return }
        do {
            games?.upsert(try await client.game(id: gameID))
        } catch {
            if error.stopsAllRequests { _ = session.report(error, from: client) }
        }
    }

    // MARK: - Helpers

    /// A cancelled request or a hand-over the coach (or the app) stopped: nothing to show.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError { return apiError.isCancellation }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// 409 `CONFLICT`: e.g. "This game's film is being analysed right now." (04 §2.1, §3).
    nonisolated static func isConflict(_ error: any Error) -> Bool {
        (error as? APIError)?.code == ErrorCode.conflict
    }

    /// An http or https link (a dropped web link goes to the video link field).
    nonisolated static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
