import Foundation
import Observation

/// Everything one open game page shows and does (03 §7.3–§7.5; DESIGN §6 [C]). `GameView` creates one
/// per game, keeps it in `@State`, injects it with `.environment(context)` and runs it with
/// `.taskWhileActive { await context.run() }`; every section of the page reads it from the environment.
///
/// **Loading (03 §7.3).** `refresh()`: `GET /api/games/{id}` first (it doubles as the one request before
/// fan-out), then in parallel the analysis (only when `has_analysis`), the jobs, and, once per page, the
/// court landmarks and `GET /api/health`; plus the reports when there is an analysis (03 §7.8). Only the
/// newest refresh draws; an older one still running is cancelled (09 R36).
///
/// **Analysis (09 R27, R28).** The 1–5 MB analysis is shown at once from `AnalysisCache` and replaced by
/// the server copy, which is fetched when the page opens, after an analysis job ends, and whenever the
/// game's `has_analysis` / `latest_job_id` / `status` changed since; a 409 `ANALYSIS_NOT_READY` means "no
/// analysis" and is not an error (09 C9).
///
/// **Jobs (03 §7.5).** `startJob`/`retryJob` return once the server accepted the job (the reload runs in
/// the background). The latest analysis job is followed every 3 s while it is active
/// (`activeAnalysisJob`), and an active report job too (`activeReportJob`). When one ends the whole page
/// reloads (09 D1 #9); after an ANALYZE that replaced the overlay film `filmRevision` grows (rebuild the
/// player item, 09 R12). While the analysis job is queued, `GET /api/health` is read at most every 15 s
/// for the "worker not running" notice. Polling stops when the page goes away or the app goes to the
/// background, and resumes on the next `run()`.
///
/// **Live games (docs/LIVE.md).** While `game.live` is not `ended` the game is read every 10 s
/// (`LivePollRule`): the banner's counters follow, the analysis is loaded again whenever
/// `live.analysisVersion` moved, and once the game has ended the page reloads as a whole (the film appears).
///
/// **Errors.** Every failure goes through `ServerSession.report(_:from:)` (lockout gate) first.
@Observable
final class GameContext: SessionActivity {
    let gameID: String

    // MARK: - Server data

    /// The game (`GET /api/games/{id}`); nil until the first load.
    private(set) var game: Game?
    /// The analysis on screen; nil when there is none (or it is being rebuilt).
    private(set) var analysis: GameAnalysis?
    /// `GET /api/games/{id}/jobs`: at most 100, newest first, every kind.
    private(set) var jobs: [Job] = []
    /// `GET /api/games/{id}/reports`, newest first (loaded with every refresh while there is an analysis).
    private(set) var reports: [ReportRecord] = []
    /// Court geometry for calibration (once per page; nil when it could not be loaded).
    private(set) var landmarks: CourtLandmarks?
    /// The server's health (once per page, and every ≥ 15 s while the analysis job is queued).
    private(set) var health: HealthStatus?

    // MARK: - Loading state

    /// The page-level error (game or analysis could not be loaded), already through the lockout gate.
    private(set) var loadError: (any PresentableError)?
    /// The reports could not be loaded (the report tab shows it; the list is then empty).
    private(set) var reportsError: (any PresentableError)?
    /// A refresh is running.
    private(set) var isRefreshing = false
    /// The first refresh has finished (with or without an error).
    private(set) var hasLoaded = false
    /// Grows at the end of every refresh that drew the page (not one that could not load the game, was
    /// replaced by a newer one or was stopped by the lockout gate): sections that reload "after each page
    /// refresh" key on it (the exports tab, exports.js `render`/`activate`).
    private(set) var refreshCount = 0
    /// The analysis is being downloaded.
    private(set) var isLoadingAnalysis = false
    /// The analysis on screen is the cached copy: the server's could not be loaded yet (09 R28).
    private(set) var isShowingCachedAnalysis = false

    // MARK: - Jobs

    /// The analysis job being followed (every 3 s); nil when none is active.
    private(set) var activeAnalysisJob: Job?
    /// The report job being followed (every 3 s); nil when none is active.
    private(set) var activeReportJob: Job?
    /// The final state of the last report job this page followed (the report tab shows a failure or a
    /// cancel; success also shows the toast "Scouting report ready").
    private(set) var finishedReportJob: Job?
    /// Following the analysis job gave up (5 failures in a row, or one that is not retryable): show it with
    /// "Check again" (`checkJobAgain()`).
    private(set) var jobTrackingError: (any PresentableError)?
    /// Following the report job gave up (`checkReportJobAgain()`).
    private(set) var reportTrackingError: (any PresentableError)?
    /// A job is being started, retried or cancelled: keep the start buttons disabled (03 §8).
    private(set) var isStartingJob = false

    // MARK: - Film and playback

    /// Grows when the film must be loaded again although its URL is the same: new film, the overlay copy
    /// appeared or changed, an ANALYZE ended (09 R12, D1 #9). The player rebuilds its item on change.
    private(set) var filmRevision = 0
    /// The player's shared state.
    let playback = PlaybackCoordinator()

    /// The analysis tab shown; remembered on this device for every game (07 §5.7).
    var selectedTab: GameTab {
        didSet { selectedTab.store(in: defaults) }
    }

    // MARK: - Dependencies

    @ObservationIgnored let session: ServerSession
    @ObservationIgnored let uploads: UploadManager?
    @ObservationIgnored let gamesStore: GamesStore?
    @ObservationIgnored let toasts: ToastCenter?
    @ObservationIgnored private let analysisCache: AnalysisCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var refreshToken = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var analysisKey: AnalysisKey?
    @ObservationIgnored private var reloadAnalysis = true
    @ObservationIgnored private var healthLoaded = false
    @ObservationIgnored private var lastWorkerCheck: Date?
    @ObservationIgnored private var analysisTracker: JobTracker?
    @ObservationIgnored private var reportTracker: JobTracker?
    @ObservationIgnored private var gaveUpAnalysisJob: Job?
    @ObservationIgnored private var gaveUpReportJob: Job?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    /// How often the worker is checked while the analysis job waits in the queue (07 §6 loop 4).
    static let workerCheckInterval: TimeInterval = 15

    /// - Parameters:
    ///   - session: the signed-in session (client, lockout gate).
    ///   - uploads: film uploads (a finished upload of this game reloads the page).
    ///   - gamesStore: the games list, kept in step with this page.
    ///   - toasts: "Scouting report ready".
    ///   - analysisCache: the analysis cache (tests pass their own).
    ///   - defaults: where the selected tab is remembered.
    ///   - sleeper: the job poller's clock (tests pass one that returns at once).
    ///   - now: the clock for the worker check.
    init(
        gameID: String,
        session: ServerSession,
        uploads: UploadManager? = nil,
        gamesStore: GamesStore? = nil,
        toasts: ToastCenter? = nil,
        analysisCache: AnalysisCache = .shared,
        defaults: UserDefaults = .standard,
        sleeper: Sleeper = .live,
        now: @escaping () -> Date = { Date() }
    ) {
        self.gameID = gameID
        self.session = session
        self.uploads = uploads
        self.gamesStore = gamesStore
        self.toasts = toasts
        self.analysisCache = analysisCache
        self.defaults = defaults
        self.sleeper = sleeper
        self.now = now
        self.selectedTab = GameTab.stored(in: defaults)
        self.health = session.health
        self.landmarks = session.courtLandmarks
        self.game = gamesStore?.game(id: gameID)
        session.register(self)
    }

    // MARK: - Derived (03 §4, §7.3–§7.4)

    /// The signed-in client; nil when nothing may be sent.
    var client: APIClient? { session.client }

    /// An uploaded film or a video link.
    var hasFilm: Bool { game?.hasFilm ?? false }

    /// Something can be played: the stored film or the overlay copy.
    var isPlayable: Bool { game?.isPlayable ?? false }

    /// An analysis job is queued or running (the game says so, or the followed job is active).
    var isBusy: Bool { game?.isBusy == true || activeAnalysisJob?.isActive == true }

    /// The game is live: its film is arriving in parts, or the last parts are being analysed (docs/LIVE.md).
    var isLive: Bool { game?.isLive ?? false }

    /// What "Re-run analysis" / "Analyze film" starts: REANALYZE with GPU results saved, else ANALYZE.
    var rerunKind: JobKind { game?.rerunKind ?? .analyze }

    /// The re-run button is enabled (03 §7.4): not busy, film or GPU results to work from, nothing starting.
    var canRerun: Bool { (game?.canRerun ?? false) && !isBusy && !isStartingJob }

    /// "Full re-analysis" is offered (film and GPU results), and enabled when `!isBusy`.
    var showsFullReanalysis: Bool { game?.showsFullReanalysis ?? false }

    /// The job panel's job: the newest analysis job (any status), with the followed job's latest state.
    var latestAnalysisJob: Job? {
        if let activeAnalysisJob { return activeAnalysisJob }
        return jobs.latestAnalysisJob
    }

    /// The job panel shows: the latest analysis job is active, failed, cancelled, or succeeded with warnings.
    var showsJobPanel: Bool { latestAnalysisJob?.showsPanel ?? false }

    /// The header badge: "Live" for a live game, "Processing · NN%" / "Queued" from the followed job, else
    /// the game's status.
    var headerBadge: BadgeLabel? { game?.liveBadge ?? activeAnalysisJob?.gameHeaderBadge ?? game?.statusBadge }

    /// The "No film yet" card is shown (03 §7.3 row 5).
    var showsNoFilmCard: Bool { game?.showsNoFilmCard(hasAnalysis: analysis != nil) ?? false }

    /// The notice while there is film but no analysis (03 §7.7).
    var pendingNotice: PendingNotice? {
        game?.pendingNotice(hasAnalysis: analysis != nil, latestAnalysisJob: latestAnalysisJob, jobPanelVisible: showsJobPanel)
    }

    /// "Film not available" (an analysis but nothing to play, 03 §7.7).
    var filmUnavailableNotice: NoticeText? { game?.filmUnavailableNotice(hasAnalysis: analysis != nil) }

    /// The "Which team is …?" banner is due (03 §7.6).
    var needsTeamConfirmation: Bool {
        guard let game, let analysis else { return false }
        return analysis.needsTeamConfirmation(for: game)
    }

    /// The worker notice under a queued analysis job (07 §3.8 rows 1–2; jobpanel.js:157-169).
    var workerNotice: NoticeText? {
        guard latestAnalysisJob?.status == .queued else { return nil }
        return health?.workerNotice
    }

    /// A team's name: the analysis's, else the game's, else "Scouted team" / "Opponent" (game.js:59-65).
    func teamName(_ side: TeamSide) -> String {
        game?.teamName(side, analysis: analysis) ?? side.shortTitle
    }

    /// The page's team colours (06 §5.1, 07 §10.3): detected colours win over the game's jersey hint.
    var teamPalette: TeamPalette {
        TeamPalette(scoutedHint: game?.scoutedColor, detectedScouted: detectedColor(.scouted), detectedOther: detectedColor(.other))
    }

    /// A team's colour (`.color` to draw, `.ink` for text on it, `Theme.teamBorder` for its border).
    func teamColor(_ side: TeamSide) -> HexColor {
        side == .other ? teamPalette.other : teamPalette.scouted
    }

    private func detectedColor(_ side: TeamSide) -> DetectedTeamColor? {
        guard let team = analysis?.team(side), team.colorRGB != nil || team.colorName != nil else { return nil }
        return DetectedTeamColor(rgb: team.colorRGB.map { [$0.red, $0.green, $0.blue] }, name: team.colorName)
    }

    // MARK: - Running

    /// The page's life: refreshes, follows jobs and reacts to finished uploads of this game until the
    /// calling task is cancelled (the page went away or the app went to the background), then stops
    /// polling. Call it from `.taskWhileActive { await context.run() }`.
    func run() async {
        await refresh()
        if let uploads {
            for await event in uploads.events where event.gameID == gameID {
                await handle(event)
            }
        } else {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3600)) } catch { break }
            }
        }
        stopTracking()
    }

    /// Stops following jobs and any refresh in flight (they resume with the next `run()` or `refresh()`).
    func stopTracking() {
        refreshTask?.cancel()
        analysisTracker?.task.cancel()
        analysisTracker = nil
        reportTracker?.task.cancel()
        reportTracker = nil
        liveTask?.cancel()
        liveTask = nil
    }

    func sessionDidStop() {
        stopTracking()
    }

    private func handle(_ event: UploadEvent) async {
        guard case .finished(let completion) = event else { return }
        if let updated = completion.game { game = updated }
        filmRevision += 1
        reloadAnalysis = true
        if let job = completion.job { adopt(job) }
        await refresh()
    }

    // MARK: - Loading (03 §7.3)

    /// Reloads the page's data (03 §7.3). The newest call wins: an older one still running is cancelled
    /// and its answers are dropped.
    func refresh() async {
        refreshTask?.cancel()
        refreshToken += 1
        let token = refreshToken
        let task = Task { await performRefresh(token: token) }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == refreshToken && !Task.isCancelled
    }

    private func performRefresh(token: Int) async {
        guard let client = session.client else { return }
        isRefreshing = true
        defer { if token == refreshToken { isRefreshing = false } }

        // Step 1: the game. It also proves the password before anything runs in parallel (02 §10 rule 2).
        let loaded: Game
        do {
            loaded = try await client.game(id: gameID)
        } catch {
            guard isCurrent(token), !error.isCancellation else { return }
            loadError = session.report(error, from: client)
            hasLoaded = true
            return
        }
        guard isCurrent(token) else { return }
        session.markReachable()

        // Step 2, in parallel.
        let id = gameID
        let key = AnalysisKey(loaded)
        let wantsAnalysis = loaded.hasAnalysis && (reloadAnalysis || analysis == nil || analysisKey != key)
        let wantsLandmarks = landmarks == nil
        let wantsHealth = !healthLoaded
        async let analysisResult = Self.fetch(if: wantsAnalysis) { try await client.analysis(gameID: id) }
        async let jobsResult = Self.fetch { try await client.jobs(gameID: id) }
        async let landmarksResult = Self.fetch(if: wantsLandmarks) { try await client.courtLandmarks() }
        async let healthResult = Self.fetch(if: wantsHealth) { try await client.health() }
        async let reportsResult = Self.fetch(if: loaded.hasAnalysis) { try await client.reports(gameID: id) }

        // Show the cached analysis while the server's downloads (09 R27).
        if wantsAnalysis {
            isLoadingAnalysis = true
            if analysis == nil, let cached = await analysisCache.load(gameID: id, generatedAt: nil), isCurrent(token), analysis == nil {
                analysis = cached
                isShowingCachedAnalysis = true
            }
        }

        let fetchedAnalysis = await analysisResult
        let fetchedJobs = await jobsResult
        let fetchedLandmarks = await landmarksResult
        let fetchedHealth = await healthResult
        let fetchedReports = await reportsResult
        guard isCurrent(token) else { return }

        // Draw: the game, its film and the analysis.
        var pageError: (any PresentableError)?
        if let previous = game, FilmIdentity(previous) != FilmIdentity(loaded) { filmRevision += 1 }
        game = loaded
        if !loaded.hasAnalysis {
            analysis = nil
            analysisKey = nil
            isShowingCachedAnalysis = false
        } else if let fetchedAnalysis {
            switch fetchedAnalysis {
            case .success(let fresh):
                analysis = fresh
                analysisKey = key
                reloadAnalysis = false
                isShowingCachedAnalysis = false
                let cache = analysisCache
                Task { await cache.store(fresh, gameID: id) }
            case .failure(let failure) where failure.code == ErrorCode.analysisNotReady:
                // 03 §4, 09 C9: no analysis right now (a Full re-analysis is rebuilding it). Not an error.
                analysis = nil
                analysisKey = nil
                isShowingCachedAnalysis = false
            case .failure(let failure):
                pageError = session.report(failure, from: client)
            }
        }
        isLoadingAnalysis = false

        // Jobs: the job panel's job comes from this list (09 R33).
        switch fetchedJobs {
        case nil:
            break
        case .success(let list)?:
            jobs = list
        case .failure(let failure)?:
            if failure.stopsAllRequests {
                _ = session.report(failure, from: client)
                return
            }
            // 03 §4: when the list fails, the latest job by its id.
            if let latestID = loaded.latestJobID {
                do {
                    let job = try await client.job(id: latestID)
                    guard isCurrent(token) else { return }
                    merge(job)
                } catch {
                    if error.stopsAllRequests {
                        _ = session.report(error, from: client)
                        return
                    }
                }
            }
        }

        if let fetchedLandmarks, case .success(let value) = fetchedLandmarks {
            landmarks = value
            session.updateCourtLandmarks(value)
        }
        if let fetchedHealth {
            switch fetchedHealth {
            case .success(let value):
                health = value
                healthLoaded = true
                lastWorkerCheck = now()
                session.updateHealth(value)
            case .failure(let failure):
                if failure.stopsAllRequests { _ = session.report(failure, from: client) }
            }
        }
        if let fetchedReports {
            switch fetchedReports {
            case .success(let list):
                reports = list
                reportsError = nil
            case .failure(let failure):
                reports = []
                reportsError = session.report(failure, from: client)
            }
        }
        guard session.client === client else { return }  // the lockout gate tripped meanwhile

        loadError = pageError
        hasLoaded = true
        gamesStore?.upsert(loaded)

        // Follow what is running (03 §7.5, §7.8).
        if let job = jobs.latestAnalysisJob {
            if job.isActive {
                gamesStore?.updateJob(job)
                track(job: job)
            } else if analysisTracker == nil {
                activeAnalysisJob = nil
            }
        }
        if let reportJob = jobs.activeReportJob { track(job: reportJob) }
        followLiveIfNeeded()
        refreshCount += 1
    }

    /// Runs `body` when `condition` holds and returns its result (nil when skipped). `body` calls one
    /// `APIClient` route, which only throws `APIError`.
    private nonisolated static func fetch<T: Sendable>(
        if condition: Bool = true,
        _ body: @Sendable () async throws -> T
    ) async -> Result<T, APIError>? {
        guard condition else { return nil }
        do {
            return .success(try await body())
        } catch let error as APIError {
            return .failure(error)
        } catch {
            return .failure(APIError.from(transportError: error, url: nil))
        }
    }

    // MARK: - Live games (docs/LIVE.md)

    /// "End live game" from a device that is not capturing the game (`POST /api/games/{id}/live/finish`): no
    /// more film is taken; the parts already sent are analysed, then the game ends. Returns once the server
    /// answered; the page keeps following the game until it has ended. On an error the page is reloaded
    /// first, then the error is thrown: pass it through `session.report(_:)` and show what it returns.
    @discardableResult
    func finishLive() async throws -> LiveStatus {
        guard let client else { throw ServerSessionError.notSignedIn }
        do {
            let status = try await client.finishLive(gameID: gameID)
            adopt(status)
            return status
        } catch {
            if !error.stopsAllRequests, !error.isCancellation { await refresh() }
            throw error
        }
    }

    /// A live status the server just answered with (start, finish; on the Mac also the capture's): shows its
    /// game and job at once and keeps following both.
    func adopt(_ status: LiveStatus) {
        guard status.game.id == gameID else { return }
        game = status.game
        gamesStore?.upsert(status.game)
        if let job = status.job { adopt(job) }
        followLiveIfNeeded()
    }

    /// Starts reading the live game every 10 s, unless that already runs or the game is not live.
    private func followLiveIfNeeded() {
        guard liveTask == nil, LivePollRule.shouldPoll(game) else { return }
        liveTask = Task { [weak self] in await self?.followLive() }
    }

    private func followLive() async {
        while !Task.isCancelled {
            do {
                try await sleeper.sleep(for: LivePollRule.interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // The page already saw the end (the followed job ended and the page reloaded): nothing left to read.
            guard LivePollRule.shouldPoll(game), let client = session.client else {
                liveTask = nil
                return
            }
            let loaded: Game
            do {
                loaded = try await client.game(id: gameID)
            } catch {
                if Task.isCancelled || error.isCancellation { return }
                if error.stopsAllRequests {
                    _ = session.report(error, from: client)
                    liveTask = nil
                    return
                }
                if error.isNotFound {
                    // Deleted from another device: the reload shows it.
                    liveTask = nil
                    await refresh()
                    return
                }
                continue  // a network problem at the gym: the next read tries again
            }
            guard !Task.isCancelled else { return }
            session.markReachable()
            switch LivePollRule.step(loaded: loaded, shownAnalysisVersion: analysis == nil ? nil : analysisKey?.liveAnalysisVersion) {
            case .update:
                game = loaded
                gamesStore?.upsert(loaded)
            case .reloadAnalysis:
                await refresh()
            case .ended:
                liveTask = nil
                reloadAnalysis = true
                await refresh()
                return
            }
        }
    }

    // MARK: - Jobs (03 §3, §7.4–§7.5)

    /// Starts a job (`POST /api/games/{id}/jobs`) and follows it (03 §7.4). It returns as soon as the server
    /// accepted the job, so the caller's toast ("Analysis started", "Re-running the analysis…", "Full
    /// re-analysis started", `Labels`) comes right after the POST as on the web; the page reloads in the
    /// background (the analysis can be 1–5 MB). On an error the page is reloaded first (09 R36: refresh after
    /// any 409), then the error is thrown: pass it through `session.report(_:)` and show what it returns.
    @discardableResult
    func startJob(_ kind: JobKind, params: [String: JSONValue] = [:]) async throws -> Job {
        guard let client else { throw ServerSessionError.notSignedIn }
        isStartingJob = true
        defer { isStartingJob = false }
        do {
            let job = try await client.startJob(gameID: gameID, JobCreate(kind: kind, params: params))
            adopt(job)
            refreshInBackground()
            return job
        } catch {
            if !error.stopsAllRequests, !error.isCancellation { await refresh() }
            throw error
        }
    }

    /// "Start again" / "Retry" / "Re-run analysis" of a finished job (`POST /api/jobs/{id}/retry`): follows
    /// the new job and returns at once; the page reloads in the background (an error reloads it first, then
    /// is thrown). Confirm first when `job.retryNeedsConfirmation(gameHasTracking:)`.
    @discardableResult
    func retryJob(_ job: Job) async throws -> Job {
        guard let client else { throw ServerSessionError.notSignedIn }
        isStartingJob = true
        defer { isStartingJob = false }
        do {
            let newJob = try await client.retryJob(id: job.id)
            adopt(newJob)
            refreshInBackground()
            return newJob
        } catch {
            if !error.stopsAllRequests, !error.isCancellation { await refresh() }
            throw error
        }
    }

    /// The page reload after a job started, without making the caller wait for it (newest refresh wins).
    private func refreshInBackground() {
        Task { [weak self] in await self?.refresh() }
    }

    /// The game's court calibration after `PUT`/`DELETE /api/games/{id}/calibration` answered (game.js
    /// `onChange`): sets it on the page's game and the games list, without a request.
    func updateCalibration(_ calibration: CourtCalibration?) {
        guard var updated = game else { return }
        updated.calibration = calibration
        game = updated
        gamesStore?.upsert(updated)
    }

    /// Asks the server to stop a job (`POST /api/jobs/{id}/cancel`); returns the job as the server has it
    /// now. Confirm first with `job.cancelQuestion`.
    @discardableResult
    func cancelJob(_ job: Job) async throws -> Job {
        guard let client else { throw ServerSessionError.notSignedIn }
        let updated = try await client.cancelJob(id: job.id)
        if updated.isActive {
            record(updated)
        } else {
            finish(updated, stopsPolling: true)
            await refresh()
        }
        return updated
    }

    /// Follows `job` every 3 s until it ends, then reloads the page (03 §7.5). Following the same job again
    /// does nothing; a newer job of the same kind (analysis / report) replaces the one followed.
    func track(job: Job) {
        guard job.isActive else {
            merge(job)
            return
        }
        if job.kind == .report {
            if reportTracker?.jobID == job.id {
                record(job)
                return
            }
            reportTracker?.task.cancel()
            activeReportJob = job
            reportTrackingError = nil
            gaveUpReportJob = nil
            finishedReportJob = nil
            reportTracker = JobTracker(jobID: job.id, task: Task { [weak self] in await self?.follow(job) })
        } else {
            if analysisTracker?.jobID == job.id {
                record(job)
                return
            }
            analysisTracker?.task.cancel()
            activeAnalysisJob = job
            jobTrackingError = nil
            gaveUpAnalysisJob = nil
            analysisTracker = JobTracker(jobID: job.id, task: Task { [weak self] in await self?.follow(job) })
        }
    }

    /// "Check again" after following the analysis job gave up: follows it again.
    func checkJobAgain() {
        jobTrackingError = nil
        if let job = gaveUpAnalysisJob ?? activeAnalysisJob {
            gaveUpAnalysisJob = nil
            analysisTracker?.task.cancel()
            analysisTracker = nil
            track(job: job)
        } else {
            Task { await refresh() }
        }
    }

    /// Follows the report job again after following it gave up.
    func checkReportJobAgain() {
        reportTrackingError = nil
        if let job = gaveUpReportJob ?? activeReportJob {
            gaveUpReportJob = nil
            reportTracker?.task.cancel()
            reportTracker = nil
            track(job: job)
        } else {
            Task { await refresh() }
        }
    }

    /// Puts a job the server returned into the list and follows it when it is active.
    private func adopt(_ job: Job) {
        merge(job)
        if job.kind != .report { gamesStore?.updateJob(job) }
        track(job: job)
    }

    /// Replaces the job with the same id in `jobs` (or puts it first, as the newest).
    private func merge(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            guard !Self.isOlder(job, than: jobs[index]) else { return }
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    /// A newer state of a followed job. An older answer (a list loaded before the last poll) is ignored, so
    /// the panel never steps back.
    private func record(_ job: Job) {
        merge(job)
        if job.kind == .report {
            guard reportTracker?.jobID == job.id || activeReportJob?.id == job.id else { return }
            if let current = activeReportJob, Self.isOlder(job, than: current) { return }
            activeReportJob = job
        } else {
            guard analysisTracker?.jobID == job.id || activeAnalysisJob?.id == job.id else { return }
            if let current = activeAnalysisJob, Self.isOlder(job, than: current) { return }
            activeAnalysisJob = job
            gamesStore?.updateJob(job)
        }
    }

    /// `job` is an earlier state of `other` (same job, older `updated_at`).
    private static func isOlder(_ job: Job, than other: Job) -> Bool {
        guard job.id == other.id, let mine = job.updatedAt, let theirs = other.updatedAt else { return false }
        return mine < theirs
    }

    /// A followed job ended.
    /// - Parameter stopsPolling: the end was seen outside the poller (a cancel's answer): its task is stopped
    ///   before it is dropped, so it does not finish the job and reload the page a second time.
    private func finish(_ job: Job, stopsPolling: Bool = false) {
        merge(job)
        if job.kind == .report {
            if reportTracker?.jobID == job.id {
                if stopsPolling { reportTracker?.task.cancel() }
                reportTracker = nil
            }
            activeReportJob = nil
            finishedReportJob = job
            if job.status == .succeeded { toasts?.show("Scouting report ready", tone: .success) }
        } else {
            if analysisTracker?.jobID == job.id {
                if stopsPolling { analysisTracker?.task.cancel() }
                analysisTracker = nil
            }
            activeAnalysisJob = nil
            gamesStore?.updateJob(job)
            reloadAnalysis = true
            // 04 §6.2, 09 R12: a GPU run that ended (or failed after its results arrived) replaced the overlay
            // film at the same URL.
            if job.kind == .analyze, job.status == .succeeded || job.failedPastTheGPU { filmRevision += 1 }
        }
    }

    private func follow(_ job: Job) async {
        guard let client = session.client else { return }
        let isReport = job.kind == .report
        var last = job
        do {
            for try await update in JobPoller.updates(jobID: job.id, client: client, sleeper: sleeper) {
                if Task.isCancelled { return }
                last = update
                record(update)
                if !isReport, update.status == .queued { await checkWorkerIfDue(client) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let shown = session.report(error, from: client)
            if isReport {
                reportTracker = nil
                gaveUpReportJob = last
                reportTrackingError = shown
            } else {
                analysisTracker = nil
                gaveUpAnalysisJob = last
                jobTrackingError = shown
            }
            return
        }
        guard !Task.isCancelled else { return }
        guard last.isTerminal else {
            // The poller stopped without an end state: the next refresh follows the job again.
            if isReport, reportTracker?.jobID == job.id { reportTracker = nil }
            if !isReport, analysisTracker?.jobID == job.id { analysisTracker = nil }
            return
        }
        finish(last)
        await refresh()
    }

    /// 07 §6 loop 4: `GET /api/health` at most every 15 s while the analysis job is queued; errors are
    /// ignored (the lockout gate still applies).
    private func checkWorkerIfDue(_ client: APIClient) async {
        let current = now()
        if let lastWorkerCheck, current.timeIntervalSince(lastWorkerCheck) < Self.workerCheckInterval { return }
        lastWorkerCheck = current
        do {
            let value = try await client.health()
            health = value
            session.updateHealth(value)
        } catch {
            if error.stopsAllRequests { _ = session.report(error, from: client) }
        }
    }

    // MARK: - Types

    /// One followed job.
    private struct JobTracker {
        let jobID: String
        let task: Task<Void, Never>
    }

    /// What decides whether the analysis on screen may be out of date.
    private nonisolated struct AnalysisKey: Hashable {
        var hasAnalysis: Bool
        var latestJobID: String?
        var status: GameStatus
        /// `live.analysis_version`: the server rebuilds a live game's analysis as its parts arrive.
        var liveAnalysisVersion: Int?

        init(_ game: Game) {
            hasAnalysis = game.hasAnalysis
            latestJobID = game.latestJobID
            status = game.status
            liveAnalysisVersion = game.live?.analysisVersion
        }
    }

    /// What decides whether the film must be loaded again.
    private nonisolated struct FilmIdentity: Hashable {
        var hasVideo: Bool
        var hasAnnotatedVideo: Bool
        var filename: String?
        var size: Int?
        var link: String?

        init(_ game: Game) {
            hasVideo = game.hasVideo
            hasAnnotatedVideo = game.hasAnnotatedVideo
            filename = game.videoFilename
            size = game.videoSize
            link = game.videoURL
        }
    }
}

// MARK: - Previews

extension GameContext {
    /// A page context filled with sample data and no server (SwiftUI previews of the page's sections).
    static func preview(
        game: Game,
        analysis: GameAnalysis? = nil,
        jobs: [Job] = [],
        reports: [ReportRecord] = [],
        health: HealthStatus? = nil,
        landmarks: CourtLandmarks? = nil,
        session: ServerSession = .preview()
    ) -> GameContext {
        let suite = UserDefaults(suiteName: "org.marquettecatholic.BasketballScout.preview") ?? .standard
        let context = GameContext(gameID: game.id, session: session, defaults: suite)
        context.game = game
        context.analysis = analysis
        context.jobs = jobs
        context.reports = reports
        context.health = health
        context.landmarks = landmarks
        context.activeAnalysisJob = jobs.latestAnalysisJob.flatMap { $0.isActive ? $0 : nil }
        context.activeReportJob = jobs.activeReportJob
        context.hasLoaded = true
        return context
    }
}
