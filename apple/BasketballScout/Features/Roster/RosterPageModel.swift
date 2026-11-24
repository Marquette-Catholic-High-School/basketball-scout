import Foundation
import Observation

/// "Rosters & jerseys" for one game (05 §7): both rosters, scouted team first, and the jersey assignments
/// from the film. `RosterView` owns one and runs it with `.taskWhileActive`.
///
/// **Loading (05 §7.13).** The game and both rosters, then the latest job and, with an analysis, the
/// tracks. Read again whenever the page appears, the app returns to the foreground or the game page is
/// refreshed (⌘R); an editor with unsaved changes keeps them and only notes a newer server copy (09 R37).
///
/// **Writes.** Explicit per-team saves (`PUT`), imports (multipart, saved at once) and "Save & re-run
/// analysis" (05 §7.7); one roster write per side at a time (05 §6.8). After any roster save the game is
/// read again and the "Roster saved" banner offers the re-run when the game has GPU results.
///
/// **Full analysis (05 §7.8).** While an ANALYZE is queued or running the assignments are locked and its job
/// is polled every 5 s, only while the page is visible (the view runs `followAnalysis()`); when it ends the
/// tracks are read again and renumbered ones drop the unsaved choices (09 D1 #6, R38).
///
/// Every API error passes through `ServerSession.report(_:from:)` (the lockout gate) before it is shown.
@Observable
final class RosterPageModel {
    /// Which page-level error box is shown.
    enum PageErrorKind: Hashable, Sendable {
        /// "Re-run analysis" could not start (with "Open the game page").
        case rerun
        /// The roster template could not be downloaded (with "Try again").
        case template
    }

    // MARK: - Dependencies

    @ObservationIgnored let context: GameContext
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let writes = RosterWriteQueue()

    // MARK: - Page

    /// The game as this page last read it.
    private(set) var game: Game?
    /// The rosters were loaded once (the editors show).
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    /// Loading failed: the page's only content before the first load, a box on top afterwards.
    private(set) var loadError: (any PresentableError)?
    /// The page-level error box (the re-run did not start, the template did not download).
    private(set) var pageError: (any PresentableError)?
    private(set) var pageErrorKind: PageErrorKind?
    /// Grows with each new page error (the iPhone list scrolls up to it).
    private(set) var pageErrorRevision = 0
    /// "Roster saved" with "Re-run analysis": after a save or import of a game with GPU results (05 §7.4).
    private(set) var showsRerunBanner = false
    private(set) var isStartingRerun = false
    private(set) var isDownloadingTemplate = false
    /// The downloaded template, until the save dialog has finished with it.
    private(set) var templateFile: DownloadedFile?
    /// The save dialog for `templateFile` is up.
    private(set) var isExportingTemplate = false
    /// A file to import into an editor with unsaved changes: asks first (05 §7.3).
    private(set) var importConfirmation: RosterImportRequest?
    /// The section shown (remembered per game for this run).
    var selection: RosterSection {
        didSet { RosterSectionMemory.remember(selection, forGame: context.gameID) }
    }

    // MARK: - Rosters

    private(set) var editors = RosterEditors()

    // MARK: - Tracks

    private(set) var tracks = RosterTracksState()
    /// The box in the tracks card (a track write failed, the tracks could not be read, …).
    private(set) var tracksError: (any PresentableError)?
    /// The roster that stopped "Save & re-run analysis" ("Show the roster").
    private(set) var tracksErrorRoster: TeamSide?
    /// What the page says by the tracks table, or where it was (roster.js `showByTracks`).
    private(set) var tracksNotice: RosterNotice?
    /// The full analysis the assignments wait for (roster.js `state.analyzing`).
    private(set) var analyzing: Job?
    /// Following that analysis gave up: the assignments stay locked until the page is reloaded.
    private(set) var stoppedChecking = false
    /// Grows to make the view follow the analysis again.
    private(set) var pollAttempt = 0
    private(set) var isSavingTracks = false

    @ObservationIgnored private var waitDropped = false
    @ObservationIgnored private var waitSaid: RosterNotice?
    @ObservationIgnored private var operations = 0
    @ObservationIgnored private var rosterRevisions: [TeamSide: Int] = [:]
    @ObservationIgnored private var tracksRevision = 0
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var lastRunGeneration: Int?

    /// Coming back to the page (from a player's screen on iPhone) sooner than this after a load does not read
    /// it again; a return to the foreground always does.
    static let refetchInterval: TimeInterval = 15

    /// - Parameters:
    ///   - context: the game page's context (session, client, toasts, the game page's job tracking).
    ///   - sleeper: the analysis poll's clock (tests pass one that returns at once).
    ///   - pollInterval: how often a running full analysis is checked (the web's 5 s).
    ///   - now: the clock for `refetchInterval`.
    init(
        context: GameContext,
        sleeper: Sleeper = .live,
        pollInterval: Duration = .seconds(5),
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.sleeper = sleeper
        self.pollInterval = pollInterval
        self.now = now
        self.game = context.game
        self.selection = RosterSectionMemory.section(forGame: context.gameID) ?? .roster(.scouted)
    }

    // MARK: - Derived

    var gameID: String { context.gameID }
    private var session: ServerSession { context.session }
    private var client: APIClient? { context.client }

    /// Unsaved roster edits or track choices: leaving asks first.
    var hasUnsavedChanges: Bool { editors.isDirty || !tracks.pending.isEmpty }

    /// A full analysis is running: track choices, "Save & re-run analysis" and "Re-run analysis" wait.
    var isLocked: Bool { analyzing != nil }

    /// The parts of the page: both rosters, and the assignments when the tracks card is shown.
    var sections: [RosterSection] {
        RosterEditors.sides.map { RosterSection.roster($0) } + (tracks.isShown ? [.tracks] : [])
    }

    /// The section to show: the chosen one, or the scouted roster when it is gone.
    var visibleSection: RosterSection {
        sections.contains(selection) ? selection : .roster(.scouted)
    }

    /// What `followAnalysis()` follows: the view restarts it when this changes.
    var pollKey: RosterPollKey { RosterPollKey(jobID: analyzing?.id, attempt: pollAttempt) }

    /// The server makes up results and may save demo rosters on its own (09 R43).
    var showsDemoNotice: Bool { (context.health ?? session.health)?.isDemoMode == true }

    /// "Save & re-run analysis" can be used (roster.js `updatePendingNote`).
    var canSaveTracks: Bool { !tracks.pending.isEmpty && analyzing == nil && !isSavingTracks && !isStartingRerun }

    /// "Re-run analysis" can be used.
    var canRerun: Bool { analyzing == nil && !isStartingRerun && !isSavingTracks }

    /// The tracks table's rows (filtered, in the web's order).
    var trackRows: [RosterTrackRow] { tracks.rows(editors: editors) }

    /// The match rate line of the tracks card; nil without tracks that count.
    var matchProjection: RosterMatchProjection? { tracks.matchProjection(editors: editors) }

    /// The "Assign to" entries of a track.
    func choiceMenu(for trackID: Int) -> RosterChoiceMenu {
        tracks.choiceMenu(for: trackID, editors: editors)
    }

    /// The choice a track's picker shows.
    func currentChoice(for trackID: Int) -> RosterTrackChoice {
        tracks.currentChoice(trackID, editors: editors)
    }

    /// The text of a track's current choice.
    func choiceTitle(for trackID: Int) -> String {
        choiceMenu(for: trackID).title(for: currentChoice(for: trackID)) ?? RosterText.automatic
    }

    /// One track's row (any filter).
    func trackRow(_ trackID: Int) -> RosterTrackRow? {
        tracks.assignments.first { $0.trackID == trackID }.map { tracks.row(for: $0, editors: editors) }
    }

    /// Notices inside the tracks section, top to bottom (roster.js `tracks-wait`, `tracks-dropped`).
    var trackSectionNotices: [RosterNotice] {
        var notices: [RosterNotice] = []
        if let tracksNotice { notices.append(tracksNotice) }
        if analyzing != nil { notices.append(stoppedChecking ? RosterText.stoppedChecking : RosterText.analysisInProgress) }
        if let removed = tracks.removedChoicesNotice { notices.append(removed) }
        return notices
    }

    /// Something is shown above the sections (errors, the banner, demo mode, notices of a hidden tracks card).
    var hasPageNotices: Bool {
        (hasLoaded && loadError != nil) || pageError != nil || showsRerunBanner || showsDemoNotice
            || !pageTrackNotices.isEmpty
    }

    /// Notices where the tracks card would be while it is hidden (roster.js `tracks-gone`).
    var pageTrackNotices: [RosterNotice] {
        guard !tracks.isShown else { return [] }
        var notices: [RosterNotice] = []
        if let tracksNotice { notices.append(tracksNotice) }
        if analyzing != nil && stoppedChecking { notices.append(RosterText.stoppedChecking) }
        return notices
    }

    // MARK: - Loading (05 §7.13 "Open screen")

    /// The page appeared, or the app came back to the foreground (`generation` grows then): loads, or reads
    /// everything again (09 R37) unless it was read moments ago in the same foreground stretch.
    func run(generation: Int = 0) async {
        defer { lastRunGeneration = generation }
        if generation == lastRunGeneration, let lastLoad, now().timeIntervalSince(lastLoad) < Self.refetchInterval {
            return
        }
        await refresh()
    }

    /// Reads the game, both rosters and, unless a full analysis is being waited for, the latest job and the
    /// tracks (roster.js `init`). Editors with unsaved changes keep them; tracks numbered again since they
    /// were shown drop the unsaved choices and say so.
    func refresh() async {
        guard let client, !isRefreshing, operations == 0 else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let id = gameID
        let revisions = rosterRevisions
        async let gameResult = Self.fetch { try await client.game(id: id) }
        async let rostersResult = Self.fetch { try await client.rosters(gameID: id) }
        let loadedGame = await gameResult
        let loadedRosters = await rostersResult
        guard !Task.isCancelled, session.client === client else { return }

        let fresh: Game
        let rosters: GameRosters
        switch (loadedGame, loadedRosters) {
        case (.success(let game), .success(let both)):
            fresh = game
            rosters = both
        case (.failure(let error), _), (_, .failure(let error)):
            if let shown = session.report(error, from: client) { loadError = shown }
            return
        }
        loadError = nil
        lastLoad = now()
        adopt(fresh)
        guard operations == 0 else { return }  // a write started meanwhile: its answers are newer
        for side in RosterEditors.sides {
            guard let roster = rosters[side] else { continue }
            if !editors[side].hasLoaded {
                editors[side].load(roster, fallbackTeamName: Self.teamName(of: fresh, side: side))
            } else if rosterRevisions[side, default: 0] != revisions[side, default: 0] || editors[side].isWriting {
                continue
            } else if editors[side].isDirty {
                editors[side].noteServerCopy(roster)
            } else {
                editors[side].load(roster, fallbackTeamName: Self.teamName(of: fresh, side: side))
            }
        }
        tracks.dropChoicesOfRemovedPlayers(editors: editors)
        hasLoaded = true

        guard analyzing == nil else {
            // The analysis poll owns the tracks meanwhile; after it gave up, this is the "reload" that checks again.
            if stoppedChecking {
                stoppedChecking = false
                pollAttempt += 1
            }
            return
        }
        let revision = tracksRevision
        let latestJobID = fresh.latestJobID
        async let latestJob = Self.fetchIf(latestJobID != nil) { try await client.job(id: latestJobID ?? "") }
        var dropped = false
        if fresh.hasAnalysis {
            dropped = await loadTracks(client, unlessChangedSince: revision)
        } else if tracks.isShown {
            // The analysis is gone (new film, or a full analysis is building a new one).
            dropped = tracks.drop()
            tracksRevision += 1
            clearTracksError()
        }
        let job = await latestJob
        guard !Task.isCancelled else { return }
        if dropped { tracksNotice = RosterText.numberedAgain(tableShown: tracks.isShown) }
        switch job {
        case .success(let job)?:
            // A full analysis running numbers the tracks again: assignments wait until it has finished.
            if Self.isFullAnalysis(job) { enterWait(job) }
        case .failure(let error)?:
            _ = session.report(error, from: client)
        case nil:
            break
        }
    }

    /// "Reload the page": reads everything again and, after polling gave up, follows the analysis again.
    func reloadPage() async {
        tracksNotice = nil
        clearTracksError()
        if stoppedChecking {
            stoppedChecking = false
            pollAttempt += 1
        }
        await refresh()
    }

    /// `GET /tracks` (roster.js `loadTracks`): shows them and returns true when the unsaved choices were dropped
    /// because the server's tracks are another run's. An error other than 404 or `ANALYSIS_NOT_READY` shows the
    /// card with the error. With `revision`, nothing is applied when the tracks changed meanwhile.
    @discardableResult
    private func loadTracks(_ client: APIClient, unlessChangedSince revision: Int? = nil) async -> Bool {
        let id = gameID
        let result = await Self.fetch { try await client.tracks(gameID: id) }
        if let revision, revision != tracksRevision || operations > 0 { return false }
        switch result {
        case .failure(let error):
            guard let shown = session.report(error, from: client) else { return false }
            if error.code != ErrorCode.analysisNotReady && error.status != 404 {
                tracks.isShown = true
                tracksError = shown
                tracksErrorRoster = nil
            }
            return false
        case .success(let state):
            let dropped = !tracks.hasSameTracks(as: state.assignments) && tracks.drop()
            tracks.show(state)
            tracksRevision += 1
            return dropped
        }
    }

    // MARK: - Editing (05 §7.2)

    /// The "Team name" field (at most 120 characters, as the web's input).
    func setTeamName(_ text: String, side: TeamSide) {
        let old = editors[side].teamName
        let accepted = RosterField.limit(text, replacing: old, maxLength: RosterField.teamNameMaxLength) ?? old
        if accepted != old { editors[side].teamName = accepted }
        if accepted != text { editors[side].teamNameRevision += 1 }
    }

    /// A cell typed in (each field keeps the web's limits; the jersey keeps digits, `#` and spaces).
    func setField(_ field: RosterField, row rowID: UUID, side: TeamSide, to text: String) {
        guard let index = editors[side].rows.firstIndex(where: { $0.id == rowID }) else { return }
        let old = editors[side].rows[index][field]
        let accepted = field.accept(text, replacing: old) ?? old
        if accepted != old {
            editors[side].rows[index][field] = accepted
            if field == .jersey, editors[side].invalidRowID == rowID { editors[side].invalidRowID = nil }
        }
        if accepted != text { editors[side].rows[index].revision += 1 }
    }

    /// "+ Add player": an empty row at the end; returns it (the view focuses its jersey).
    @discardableResult
    func addRow(_ side: TeamSide) -> UUID {
        let row = RosterRowDraft()
        editors[side].rows.append(row)
        return row.id
    }

    /// "×" (or Delete): the rows go; unsaved track choices for their players go too, and the page says which
    /// tracks (05 §7.10).
    func removeRows(_ ids: Set<UUID>, side: TeamSide) {
        guard !ids.isEmpty else { return }
        editors[side].rows.removeAll { ids.contains($0.id) }
        if let invalid = editors[side].invalidRowID, ids.contains(invalid) { editors[side].invalidRowID = nil }
        tracks.dropChoicesOfRemovedPlayers(editors: editors)
    }

    /// "Replace this roster" / "Merge (update matching jerseys)".
    func setImportMode(_ mode: RosterImportMode, side: TeamSide) {
        editors[side].importMode = mode
    }

    /// "Use the server's roster": the newer server copy replaces the unsaved edits.
    func useServerCopy(_ side: TeamSide) {
        guard let roster = editors[side].newerServerCopy else { return }
        editors[side].load(roster, fallbackTeamName: game.map { Self.teamName(of: $0, side: side) })
        rosterRevisions[side, default: 0] += 1
        tracks.dropChoicesOfRemovedPlayers(editors: editors)
    }

    /// "Keep my changes": the notice goes; saving replaces the server's roster.
    func keepMyChanges(_ side: TeamSide) {
        editors[side].newerServerCopy = nil
    }

    // MARK: - Saving (05 §7.2, §7.13)

    /// "Save roster": checks the rows, `PUT /rosters/{side}`, shows the answer (the server's ids for new
    /// players), then the post-save steps. True when saved.
    @discardableResult
    func saveRoster(_ side: TeamSide) async -> Bool {
        operations += 1
        defer { operations -= 1 }
        return await writeRoster(side)
    }

    private func writeRoster(_ side: TeamSide) async -> Bool {
        guard let client else { return false }
        await writes.acquire(side.rawValue)
        defer { writes.release(side.rawValue) }
        editors[side].error = nil
        switch editors[side].collect() {
        case .problem(let message, let index):
            editors[side].error = DisplayError(title: RosterText.checkTheRoster, message: message)
            editors[side].invalidRowID = editors[side].rows.indices.contains(index) ? editors[side].rows[index].id : nil
            return false
        case .players(let players):
            let id = gameID
            let body = RosterReplace(teamName: FormText.trimmed(editors[side].teamName), players: players)
            editors[side].isWriting = true
            let result = await Self.fetch { try await client.replaceRoster(gameID: id, side: side, body) }
            editors[side].isWriting = false
            switch result {
            case .success(let roster):
                editors[side].load(roster)
                rosterRevisions[side, default: 0] += 1
                await rosterSaved(client)
                return true
            case .failure(let error):
                editors[side].error = session.report(error, from: client)
                return false
            }
        }
    }

    /// After a save or import (roster.js `onRosterSaved`): the toast, unsaved choices for players no longer on
    /// the roster go, the game is read again (the banner shows iff it has GPU results) and, with tracks shown,
    /// the overrides the server kept (it deletes those of removed players) unless the tracks were renumbered.
    private func rosterSaved(_ client: APIClient) async {
        context.toasts?.show(RosterText.rosterSavedToast, tone: .success)
        tracks.dropChoicesOfRemovedPlayers(editors: editors)
        let id = gameID
        let wantsTracks = !tracks.assignments.isEmpty
        async let gameResult = Self.fetch { try await client.game(id: id) }
        async let tracksResult = Self.fetchIf(wantsTracks) { try await client.tracks(gameID: id) }
        let loadedGame = await gameResult
        let loadedTracks = await tracksResult
        switch loadedGame {
        case .success(let fresh): adopt(fresh)
        case .failure(let error): _ = session.report(error, from: client)
        }
        showsRerunBanner = game?.hasTracking == true
        switch loadedTracks {
        case .success(let state)?:
            // Tracks numbered again are for "Save & re-run analysis" to find.
            if tracks.hasSameTracks(as: state.assignments) {
                tracks.overrides = RosterTracksState.byTrack(state.overrides)
                tracksRevision += 1
            }
        case .failure(let error)?:
            _ = session.report(error, from: client)
        case nil:
            break
        }
    }

    // MARK: - Import (05 §4.4, §7.3; 09 D1 #7, R40)

    /// A file picked or dropped for `side`: the web's checks (extension, 2 MB) first; with unsaved changes the
    /// question "Importing replaces your unsaved changes…" comes next (`importConfirmation`).
    func requestImport(_ file: RosterImportFile, side: TeamSide) async {
        editors[side].error = nil
        if let problem = RosterImportCheck.unsupportedProblem(filename: file.filename) {
            editors[side].error = problem
            file.discard()
            return
        }
        if let bytes = await RosterImportCheck.fileSize(of: file.url),
           let problem = RosterImportCheck.tooLargeProblem(filename: file.filename, bytes: bytes) {
            editors[side].error = problem
            file.discard()
            return
        }
        if editors[side].isDirty {
            importConfirmation?.file.discard()
            importConfirmation = RosterImportRequest(side: side, file: file)
            return
        }
        await importFile(file, side: side)
    }

    /// "Continue": imports the file asked about.
    func confirmImport(_ request: RosterImportRequest) {
        guard importConfirmation?.id == request.id else { return }
        importConfirmation = nil
        Task { await importFile(request.file, side: request.side) }
    }

    /// "Cancel": nothing is imported.
    func cancelImport(_ request: RosterImportRequest) {
        guard importConfirmation?.id == request.id else { return }
        importConfirmation = nil
        request.file.discard()
    }

    /// `POST /rosters/{side}/import` with the file under its own name and `mode` as a form field. The server
    /// saves at once; the editor shows the answer and the summary stays until the next import.
    func importFile(_ file: RosterImportFile, side: TeamSide) async {
        defer { file.discard() }
        guard let client else { return }
        operations += 1
        defer { operations -= 1 }
        await writes.acquire(side.rawValue)
        defer { writes.release(side.rawValue) }
        let id = gameID
        let url = file.url
        let mode = editors[side].importMode
        editors[side].error = nil
        editors[side].importStatus = .reading(filename: file.filename)
        editors[side].isWriting = true
        let result = await Self.fetch {
            try await client.importRoster(gameID: id, side: side, fileURL: url, mode: mode)
        }
        editors[side].isWriting = false
        switch result {
        case .success(let imported):
            let changes = RosterImportChanges(before: editors[side].saved, after: imported.roster.players)
            editors[side].load(imported.roster)
            editors[side].importStatus = .imported(filename: file.filename, result: imported, changes: changes)
            rosterRevisions[side, default: 0] += 1
            await rosterSaved(client)
        case .failure(let error):
            editors[side].importStatus = nil
            editors[side].error = session.report(error, from: client)
        }
    }

    // MARK: - Template (05 §4.8, §9.6)

    /// "Download roster template": downloads it (it needs the password like everything else), then the view
    /// offers the save dialog.
    func downloadTemplate() async {
        guard let client, !isDownloadingTemplate else { return }
        isDownloadingTemplate = true
        defer { isDownloadingTemplate = false }
        if pageErrorKind == .template { clearPageError() }
        let result = await Self.fetch { try await client.downloadRosterTemplate() }
        switch result {
        case .success(let file):
            templateFile?.remove()
            templateFile = file
            isExportingTemplate = true
        case .failure(let error):
            if let shown = session.report(error, from: client) { showPageError(shown, kind: .template) }
        }
    }

    /// The save dialog went away (its completion deletes the file).
    func templateExportDismissed() {
        isExportingTemplate = false
    }

    /// The save dialog saved or was cancelled: the temporary file goes.
    func finishTemplateExport() {
        templateFile?.remove()
        templateFile = nil
        isExportingTemplate = false
    }

    // MARK: - Track choices (05 §7.6)

    /// The "Show" filter.
    func setFilter(_ filter: RosterTrackFilter) {
        tracks.filter = filter
    }

    /// A choice in a track's picker: pending unless it changes nothing. Ignored while locked or saving.
    func choose(_ choice: RosterTrackChoice, for trackID: Int) {
        guard analyzing == nil, !isSavingTracks else { return }
        tracks.choose(choice, for: trackID, editors: editors)
    }

    // MARK: - Re-run (05 §7.4, §4.12)

    /// "Re-run analysis" in the banner. Returns the started job: go back to the game page, which follows it
    /// (`returnToGame(following:)`).
    func rerun() async -> Job? {
        guard let client, canRerun else { return nil }
        isStartingRerun = true
        operations += 1
        defer {
            isStartingRerun = false
            operations -= 1
        }
        return await startReanalysis(client)
    }

    /// `POST /jobs {"kind":"reanalyze"}` (the web then opens the game page). A failure shows "Open the game page"
    /// and the toast "Your changes are saved, but the analysis did not start."; a 409 checks for a full analysis
    /// to wait for.
    private func startReanalysis(_ client: APIClient) async -> Job? {
        let id = gameID
        let result = await Self.fetch { try await client.startJob(gameID: id, .reanalyze) }
        switch result {
        case .success(let job):
            context.gamesStore?.updateJob(job)
            context.toasts?.show(RosterText.rerunStartedToast)
            return job
        case .failure(let error):
            guard let shown = session.report(error, from: client) else { return nil }
            showPageError(shown, kind: .rerun)
            context.toasts?.show(RosterText.rerunFailedToast, tone: .danger)
            if error.status == 409 { await checkForAnalysis(client) }
            return nil
        }
    }

    /// The page goes back to the game page after starting `job`: the game page follows it from now on (its
    /// poller runs while it is visible).
    func returnToGame(following job: Job?) {
        if let job { context.track(job: job) }
    }

    // MARK: - Save & re-run analysis (05 §7.7)

    /// "Save & re-run analysis": saves edited rosters first (new players get their ids, removed players'
    /// overrides go), reads the tracks again and sends nothing when a full analysis numbered them again,
    /// sends the choices in the order made (Automatic deletes; a 404 is fine), then starts the re-run. Returns
    /// the started job: go back to the game page.
    func saveTracksAndRerun() async -> Job? {
        guard let client, canSaveTracks else { return nil }
        isSavingTracks = true
        operations += 1
        defer {
            isSavingTracks = false
            operations -= 1
        }
        clearTracksError()
        tracks.removedChoicesHint = nil  // clicked again: its "click again" goes
        let choices = tracks.pending.count
        for side in RosterEditors.sides where editors[side].isDirty {
            guard await writeRoster(side) else {
                tracksError = DisplayError(title: RosterText.rosterNotSavedTitle, message: RosterText.rosterNotSavedMessage)
                tracksErrorRoster = side
                return nil
            }
        }
        // The saved roster lost a player some choices named: send nothing yet, so the coach sees which.
        if tracks.pending.count < choices {
            if !tracks.pending.isEmpty { tracks.removedChoicesHint = RosterText.otherChoicesNotSaved }
            return nil
        }
        let id = gameID
        let fetched = await Self.fetch { try await client.tracks(gameID: id) }
        let fresh: TrackState
        switch fetched {
        case .success(let state):
            fresh = state
        case .failure(let error):
            tracksError = session.report(error, from: client)
            return nil
        }
        // A full analysis since the table was loaded (09 D1 #6): the choices would land on other players.
        guard tracks.hasSameTracks(as: fresh.assignments) else {
            await tracksNumberedAgain(fresh, client: client)
            return nil
        }
        tracks.overrides = RosterTracksState.byTrack(fresh.overrides)
        tracksRevision += 1
        do {
            try await sendPendingChoices(client)
        } catch {
            tracksError = session.report(error, from: client)
            if error.status == 409 { await checkForAnalysis(client) }
            return nil
        }
        return await startReanalysis(client)
    }

    /// Sends each pending choice, oldest first; each one sent stops being pending.
    private func sendPendingChoices(_ client: APIClient) async throws(APIError) {
        let id = gameID
        for entry in tracks.pending.entries {
            if let body = tracks.body(for: entry.trackID, choice: entry.choice) {
                let saved = try await client.setTrackOverride(gameID: id, trackID: entry.trackID, body)
                tracks.overrides[entry.trackID] = saved
            } else {
                if tracks.overrides[entry.trackID] != nil {
                    do {
                        try await client.deleteTrackOverride(gameID: id, trackID: entry.trackID)
                    } catch {
                        // 404: the roster save already dropped it (05 §4.11).
                        if !error.isNotFound { throw error }
                    }
                }
                tracks.overrides[entry.trackID] = nil
            }
            tracks.pending.remove(entry.trackID)
            tracksRevision += 1
        }
    }

    /// The tracks were numbered again since the table was loaded (roster.js `tracksNumberedAgain`): while the
    /// full analysis still runs, wait for it; otherwise drop the choices and show the new table, or none.
    private func tracksNumberedAgain(_ fresh: TrackState, client: APIClient) async {
        let id = gameID
        let loaded = await Self.fetch { try await client.game(id: id) }
        let freshGame: Game
        switch loaded {
        case .success(let value):
            freshGame = value
        case .failure(let error):
            tracksError = session.report(error, from: client)
            return
        }
        if let latestID = freshGame.latestJobID {
            switch await Self.fetch({ try await client.job(id: latestID) }) {
            case .success(let job):
                if Self.isFullAnalysis(job) {
                    enterWait(job)
                    return
                }
            case .failure(let error):
                _ = session.report(error, from: client)
            }
        }
        adopt(freshGame)
        tracks.drop()
        tracks.show(fresh)
        tracksRevision += 1
        tracksNotice = RosterText.numberedAgain(tableShown: tracks.isShown)
    }

    /// After a 409 from a track write or the re-run: a full analysis started since the page loaded is waited
    /// for (roster.js `checkForAnalysis`).
    private func checkForAnalysis(_ client: APIClient) async {
        let id = gameID
        let loaded = await Self.fetch { try await client.game(id: id) }
        let freshGame: Game
        switch loaded {
        case .success(let value):
            freshGame = value
        case .failure(let error):
            _ = session.report(error, from: client)
            return
        }
        adopt(freshGame)
        guard let latestID = freshGame.latestJobID else { return }
        switch await Self.fetch({ try await client.job(id: latestID) }) {
        case .success(let job):
            if Self.isFullAnalysis(job) { enterWait(job) }
        case .failure(let error):
            _ = session.report(error, from: client)
        }
    }

    // MARK: - A full analysis running (05 §7.8)

    /// An ANALYZE queued or running: its new run numbers the tracks again and clears their assignments.
    nonisolated static func isFullAnalysis(_ job: Job) -> Bool {
        job.kind == .analyze && job.isActive
    }

    /// The ANALYZE put its new tracking in place: it succeeded, or failed after that (the server's rule for its
    /// retry; a late cancel ends `succeeded`, 05 §7.8).
    nonisolated static func tracksRenumbered(_ job: Job) -> Bool {
        job.kind == .analyze && (job.status == .succeeded || job.failedPastTheGPU)
    }

    /// Locks the assignments and starts following `job` (roster.js `waitForAnalysis`; nothing when already
    /// waiting). With the table shown, the waiting notice replaces what was said by it.
    private func enterWait(_ job: Job) {
        guard analyzing == nil else { return }
        waitDropped = false
        waitSaid = nil
        stoppedChecking = false
        if tracks.isShown { tracksNotice = nil }
        analyzing = job
    }

    /// Follows the full analysis the page waits for: `GET /api/jobs/{id}` at once, then every 5 s until it ends
    /// (5 failures in a row, or one that is not retryable, stop it: "Stopped checking the film analysis").
    /// The view runs this with `.taskWhileActive(id: pollKey)`, so it stops when the page is hidden or the app
    /// is in the background and polls at once on return (09 R29, 05 §9.12).
    func followAnalysis() async {
        guard let job = analyzing, !stoppedChecking, let client else { return }
        var last: Job?
        do {
            for try await update in JobPoller.updates(jobID: job.id, client: client, every: pollInterval, sleeper: sleeper) {
                last = update
            }
        } catch {
            guard !Task.isCancelled, analyzing?.id == job.id else { return }
            _ = session.report(error, from: client)
            if session.client === client { stoppedChecking = true }
            return
        }
        guard !Task.isCancelled, analyzing?.id == job.id, let final = last, final.isTerminal else { return }
        await analysisEnded(job, final: final, client: client)
    }

    /// The waited-for analysis ended (roster.js `waitForAnalysis`, after `pollJob`): read the game; if another
    /// full analysis is now running (started elsewhere), wait for it with the table locked. Renumbered tracks
    /// (or a game left without an analysis) drop the unsaved choices; the tracks are read again; the page
    /// says what happened. Interrupted (the page went away), it runs again on return.
    private func analysisEnded(_ job: Job, final: Job, client: APIClient) async {
        let id = gameID
        let loaded = await Self.fetch { try await client.game(id: id) }
        guard !Task.isCancelled else { return }
        var freshGame: Game?
        switch loaded {
        case .success(let value): freshGame = value
        case .failure(let error): _ = session.report(error, from: client)
        }
        var next: Job?
        if let latestID = freshGame?.latestJobID, latestID != job.id {
            let latest = await Self.fetch { try await client.job(id: latestID) }
            guard !Task.isCancelled else { return }
            switch latest {
            case .success(let value): if Self.isFullAnalysis(value) { next = value }
            case .failure(let error): _ = session.report(error, from: client)
            }
        }
        guard session.client === client else { return }
        let tableShown = tracks.isShown
        let hadRows = tableShown && !tracks.assignments.isEmpty
        if Self.tracksRenumbered(final) || freshGame?.hasAnalysis == false {
            // Installing a new run deletes the earlier analysis first: without one, none of its tracks remain.
            waitDropped = tracks.drop() || waitDropped
            tracksRevision += 1
        }
        if let freshGame { adopt(freshGame) }
        clearTracksError()
        if pageErrorKind == .rerun { clearPageError() }
        if next == nil { tracksNotice = nil }
        let renumbered = game?.hasAnalysis == true ? await loadTracks(client) : false
        guard !Task.isCancelled else { return }
        let notice: RosterNotice?
        if renumbered {
            waitDropped = true
            notice = RosterText.numberedAgain(tableShown: tracks.isShown)
        } else {
            notice = RosterText.analysisFinished(
                dropped: waitDropped, tableShownBefore: tableShown, hadRows: hadRows,
                tableShownNow: tracks.isShown, hasRowsNow: !tracks.assignments.isEmpty)
        }
        if let next {
            waitSaid = notice ?? waitSaid
            tracksNotice = waitSaid
            analyzing = next
        } else {
            tracksNotice = notice
            waitDropped = false
            waitSaid = nil
            analyzing = nil
        }
    }

    // MARK: - Helpers

    private func adopt(_ fresh: Game) {
        game = fresh
        context.gamesStore?.upsert(fresh)
    }

    private func showPageError(_ error: any PresentableError, kind: PageErrorKind) {
        pageError = error
        pageErrorKind = kind
        pageErrorRevision += 1
    }

    private func clearPageError() {
        pageError = nil
        pageErrorKind = nil
    }

    private func clearTracksError() {
        tracksError = nil
        tracksErrorRoster = nil
    }

    /// The game's name for `side` (an editor shows it while the roster has none, roster.js:805-806).
    nonisolated static func teamName(of game: Game, side: TeamSide) -> String {
        side == .other ? game.otherTeam : game.scoutedTeam
    }

    /// Runs one `APIClient` call (which only throws `APIError`) and returns its result.
    private nonisolated static func fetch<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, APIError> {
        do {
            return .success(try await body())
        } catch let error as APIError {
            return .failure(error)
        } catch {
            return .failure(APIError.from(transportError: error, url: nil))
        }
    }

    /// `fetch` when `condition` holds; nil when skipped.
    private nonisolated static func fetchIf<T: Sendable>(
        _ condition: Bool, _ body: @Sendable () async throws -> T
    ) async -> Result<T, APIError>? {
        guard condition else { return nil }
        return await fetch(body)
    }
}

/// What the analysis poll follows: a new job, or "check again", restarts it.
nonisolated struct RosterPollKey: Hashable, Sendable {
    let jobID: String?
    let attempt: Int
}

/// A file waiting for "Importing replaces your unsaved changes to this roster. Continue?".
nonisolated struct RosterImportRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let side: TeamSide
    let file: RosterImportFile
}

// MARK: - Previews

extension RosterPageModel {
    /// A page filled with sample data and no server (SwiftUI previews).
    static func preview(
        context: GameContext,
        rosters: GameRosters,
        tracks: TrackState = TrackState(),
        analyzing: Job? = nil,
        showsRerunBanner: Bool = false,
        selection: RosterSection = .roster(.scouted),
        edit: (RosterPageModel) -> Void = { _ in }
    ) -> RosterPageModel {
        let model = RosterPageModel(context: context)
        model.game = context.game
        for side in RosterEditors.sides {
            if let roster = rosters[side] {
                model.editors[side].load(roster, fallbackTeamName: context.game.map { teamName(of: $0, side: side) })
            }
        }
        model.tracks.show(tracks)
        model.analyzing = analyzing
        model.showsRerunBanner = showsRerunBanner
        model.selection = selection
        model.hasLoaded = true
        edit(model)
        return model
    }
}
