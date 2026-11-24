import Observation
import SwiftUI

/// The app's shared state (DESIGN §6 [C]): the session, uploads, games list and toasts, plus what the
/// window shows (selected game, pushed screens, sheets). Injected with `.environment(appModel)` and its
/// parts with `.environment(appModel.session)` etc.
///
/// It wires the parts together (B2 handoff): uploads use the signed-in client and report their errors
/// to the lockout gate; the gate suspends uploads; uploads continue once a signed-in request went
/// through; another server forgets the old one's uploads and cached analyses.
@Observable
final class AppModel {
    let session: ServerSession
    let uploads: UploadManager
    let games: GamesStore
    let toasts: ToastCenter
    #if os(macOS)
    /// The Mac's live captures (docs/LIVE.md): owned here, so a capture carries on while the coach looks at
    /// other games or closes the window.
    let liveCapture: LiveCaptureCenter
    #endif

    /// The game shown in the detail column (nil: none).
    var selectedGameID: String? {
        didSet {
            guard selectedGameID != oldValue else { return }
            gamePath = []
            if pendingRoute?.gameID != selectedGameID { pendingRoute = nil }
        }
    }
    /// Screens pushed on the selected game (roster, film).
    var gamePath: [GameRoute] = []
    /// The New game sheet.
    var showNewGame = false
    /// The Settings sheet (iPhone and iPad; the Mac has a Settings window).
    var showSettings = false
    /// The System status popover / sheet.
    var showSystemStatus = false
    /// Foreground state for `taskWhileActive` (09 R29).
    private(set) var activity = AppActivity.initial

    @ObservationIgnored private var contexts: [ObjectIdentifier: WeakGameContext] = [:]
    /// A screen to push once the newly selected game's page is shown (`open(gameID:route:)`).
    @ObservationIgnored private var pendingRoute: (gameID: String, route: GameRoute)?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var wasInBackground = false
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(session: ServerSession, uploads: UploadManager, games: GamesStore, toasts: ToastCenter) {
        self.session = session
        self.uploads = uploads
        self.games = games
        self.toasts = toasts
        #if os(macOS)
        self.liveCapture = LiveCaptureCenter()
        #endif
        wire()
    }

    /// The app's real parts.
    convenience init() {
        let session = ServerSession()
        self.init(session: session, uploads: UploadManager(), games: GamesStore(session: session), toasts: ToastCenter())
    }

    private func wire() {
        uploads.clientProvider = { [weak session] in session?.client }
        uploads.maxUploadBytesProvider = { [weak session] in session?.health?.maxUploadBytes }
        uploads.errorReporter = { [weak session] error in _ = session?.report(error) }

        session.onStopAll = { [weak self] _ in
            guard let self else { return }
            uploads.suspendAll()
            showNewGame = false
            showSettings = false
            showSystemStatus = false
        }
        session.onReachable = { [weak self] in
            self?.uploads.resumePendingUploads()
        }
        session.onServerChanged = { [weak self] in
            guard let self else { return }
            uploads.removeAll()
            games.reset()
            selectedGameID = nil
            #if os(macOS)
            liveCapture.reset()
            #endif
        }
        session.onSignedOut = { [weak self] in
            guard let self else { return }
            games.reset()
            selectedGameID = nil
            #if os(macOS)
            liveCapture.reset()
            #endif
        }
        #if os(macOS)
        // A capture sends with the signed-in client and waits while there is none (the lockout gate); what the
        // server answers it with goes to the games list and the game's open page.
        liveCapture.apiProvider = { [weak session] in session?.client }
        liveCapture.serverProvider = { [weak session] in session?.address }
        liveCapture.errorReporter = { [weak session] error, api in _ = session?.report(error, from: api as? APIClient) }
        liveCapture.onStatus = { [weak self] status in
            guard let self else { return }
            games.upsert(status.game)
            context(for: status.game.id)?.adopt(status)
        }
        #endif
        games.didDelete = { [weak self] gameID in
            guard let self else { return }
            uploads.dismiss(gameID: gameID)
            Task { await AnalysisCache.shared.remove(gameID: gameID) }
            if selectedGameID == gameID { selectedGameID = nil }
        }
    }

    // MARK: - Launch and life cycle

    /// At launch (once): removes leftover temporary files, listens to upload events and signs in again with
    /// the saved server. Does nothing in unit tests.
    func start() async {
        guard !didStart else { return }
        didStart = true
        guard !AppEnvironment.isRunningTests else { return }
        Self.removeLeftoverFiles()
        listenToUploads()
        await session.restore()
    }

    /// Deletes the temporary files an earlier run left behind (they can name minors): downloaded exports
    /// (`tmp/Exports`) and copies of dropped roster files whose import was interrupted (`tmp/RosterImports`).
    /// - Parameter root: the temporary directory (tests pass their own).
    static func removeLeftoverFiles(under root: URL = FileManager.default.temporaryDirectory) {
        DownloadedFile.removeAll(under: root)
        RosterImportFile.removeLeftoverCopies(under: root)
    }

    /// Scene phase changes (09 R29): polling stops in the background; on return, ONE `GET /api/health`
    /// runs before the screens reload (02 §10 rule 2).
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
            activity.isActive = false
        case .active:
            guard wasInBackground else {
                activity.isActive = true
                return
            }
            wasInBackground = false
            Task {
                if session.isSignedIn { await session.revalidate() }
                // Back in the background meanwhile: the next return starts the screens.
                guard !wasInBackground else { return }
                activity = AppActivity(isActive: true, generation: activity.generation + 1)
            }
        default:
            break
        }
    }

    private func listenToUploads() {
        eventsTask?.cancel()
        let stream = uploads.events
        eventsTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: UploadEvent) {
        guard case .finished(let completion) = event else { return }
        if let game = completion.game {
            games.upsert(game)
        } else {
            Task { await games.refresh() }
        }
        if completion.filmSavedWithoutAnalysis {
            // 09 R19: the film IS saved; the game page offers "Analyze film".
            toasts.show("The film is saved, but the analysis did not start.", tone: .danger)
        }
    }

    // MARK: - Navigation

    /// The selected game, as the list has it.
    var selectedGame: Game? {
        selectedGameID.flatMap { id in context(for: id)?.game ?? games.game(id: id) }
    }

    /// Opens a game in the detail column.
    func open(gameID: String) {
        selectedGameID = gameID
    }

    /// Opens a game with `route` on top of its page (the games list's Roster, Add film, Show upload), in place of
    /// whatever was pushed; nil shows the page itself. For a game not selected yet the route is pushed once its
    /// page is on screen (`gamePageAppeared(_:)`): a collapsed split view (iPhone) pushes the page for the new
    /// selection first and drops a route set in the same update.
    func open(gameID: String, route: GameRoute?) {
        guard selectedGameID != gameID else {
            gamePath = route.map { [$0] } ?? []
            return
        }
        selectedGameID = gameID
        pendingRoute = route.map { (gameID, $0) }
    }

    /// The page of `gameID` is on screen: pushes the route `open(gameID:route:)` asked for with it.
    func gamePageAppeared(_ gameID: String) {
        guard let pending = pendingRoute, pending.gameID == gameID, selectedGameID == gameID else { return }
        pendingRoute = nil
        gamePath = [pending.route]
    }

    /// Pushes a screen on the selected game.
    func navigate(to route: GameRoute) {
        guard selectedGameID != nil else { return }
        if gamePath.last != route { gamePath.append(route) }
    }

    /// Pops `route` (and anything above it) off the selected game.
    func pop(_ route: GameRoute) {
        if let index = gamePath.lastIndex(of: route) {
            gamePath.removeSubrange(index...)
        }
    }

    /// The New game sheet (⌘N).
    func presentNewGame() {
        guard session.isSignedIn else { return }
        showNewGame = true
    }

    /// "Add Film…" / "Replace Film…" (⌘U) for the open game. Not while it is live: its film is arriving.
    func openFilmForSelectedGame() {
        guard canOpenFilmForSelectedGame else { return }
        navigate(to: .film)
    }

    /// The film command is enabled: signed in, a game is open, and it is not live.
    var canOpenFilmForSelectedGame: Bool {
        session.isSignedIn && selectedGameID != nil && selectedGame?.isLive != true
    }

    /// The film command's title for the open game.
    var filmCommandTitle: String {
        selectedGame?.hasFilm == true ? "Replace Film…" : "Add Film…"
    }

    /// Refresh (⌘R): the games list, the server's health (the System status row, as reloading the web's
    /// home page does, 07 §3.2) and every open game page.
    func refreshAll() async {
        guard session.isSignedIn else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.games.refresh() }
            group.addTask { await self.session.refreshHealth() }
            for context in openContexts {
                group.addTask { await context.refresh() }
            }
        }
    }

    // MARK: - Open game pages

    /// Keeps track of an open game page (for ⌘R).
    func register(_ context: GameContext) {
        contexts = contexts.filter { $0.value.context != nil }
        contexts[ObjectIdentifier(context)] = WeakGameContext(context: context)
    }

    /// The open game pages.
    var openContexts: [GameContext] {
        contexts.values.compactMap(\.context)
    }

    /// The open page of `gameID`, if any.
    func context(for gameID: String) -> GameContext? {
        openContexts.first { $0.gameID == gameID }
    }

    private struct WeakGameContext {
        weak var context: GameContext?
    }
}

// MARK: - Previews

extension AppModel {
    /// An app model for SwiftUI previews: a session in `state` that never sends anything, and `games`.
    static func preview(state: ServerSession.State = .signedIn, games: [Game] = [], health: HealthStatus? = nil) -> AppModel {
        let session = ServerSession.preview(state: state, health: health)
        let directory = FileManager.default.temporaryDirectory.appending(path: "PreviewUploads", directoryHint: .isDirectory)
        return AppModel(
            session: session,
            uploads: UploadManager(store: UploadStore(directory: directory)),
            games: .preview(games: games, session: session),
            toasts: ToastCenter())
    }
}
