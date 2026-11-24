import Foundation
import Observation

/// The games list (07 §3, 03 §7.1): every game in the server's order (newest created first, no client
/// sorting), with the latest analysis job of each queued/processing game for its progress block.
///
/// - `refresh()`: `GET /api/games`, then `GET /api/jobs/{latest_job_id}` for every queued/processing
///   game, in parallel; a failed job fetch is ignored (that card shows "Waiting for the worker…").
///   The newest refresh wins. On error the list on screen stays and `error` is set ("Try again").
/// - `poll()`: the web's loop (07 §6 loop 1): refresh, then again 5 s after each load while any game is
///   queued/processing, 10 s after a retryable error, and stop on any other error. While a game is live
///   (docs/LIVE.md: `ready` for most of the game) it refreshes every 10 s, so the "Live" badge goes when the
///   game ends. When nothing is active it sleeps until a game becomes active (`upsert`) or `refresh()` finds
///   one. Run it from the list's
///   `.taskWhileActive` so it stops in the background and when the list is not visible (09 R29).
@Observable
final class GamesStore: SessionActivity {
    /// Every game, newest created first.
    private(set) var games: [Game] = []
    /// The latest analysis job of each queued/processing game, by game id (07 §3.6).
    private(set) var latestJobs: [String: Job] = [:]
    /// A load is running.
    private(set) var isLoading = false
    /// The last load failed (already passed through the lockout gate); the list on screen is kept.
    private(set) var error: (any PresentableError)?
    /// The list has been loaded at least once.
    private(set) var hasLoaded = false
    /// When the list was last loaded.
    private(set) var lastLoadedAt: Date?

    /// Called after a game was deleted (forget its upload, cached analysis and selection).
    @ObservationIgnored var didDelete: (String) -> Void = { _ in }

    @ObservationIgnored let session: ServerSession
    @ObservationIgnored private let wake = PollWakeSignal()
    /// A polling loop runs (`poll()` is single-flight).
    @ObservationIgnored private var isPolling = false
    /// Wakes callers of `poll()` waiting for the running loop to end.
    @ObservationIgnored private let pollEnded = PollWakeSignal()
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// The web's interval while film is processing (07 §6).
    static let activeInterval: Duration = .seconds(5)
    /// The web's retry after a retryable error (07 §3.2).
    static let retryInterval: Duration = .seconds(10)
    /// The interval while a game is live and nothing else is processing (the game page's rate, `LivePollRule`).
    static let liveInterval: Duration = LivePollRule.interval
    /// The list's note while it updates itself (07 §3.2).
    static let updatingNote = "Updating every 5 seconds while film is processing"
    /// The note while only a live game keeps the list updating.
    static let liveUpdatingNote = "Updating while a game is live"

    init(session: ServerSession) {
        self.session = session
        session.register(self)
    }

    // MARK: - Reading

    /// Some game is queued or processing.
    var hasActiveGames: Bool { games.contains { $0.isBusy } }

    /// Some game is live (its film is arriving, or its last parts are being analysed).
    var hasLiveGames: Bool { games.contains { $0.isLive } }

    /// "Updating every 5 seconds while film is processing" while a game is active, "Updating while a game is
    /// live" while one is live, else nil.
    var refreshNote: String? {
        if hasActiveGames { return Self.updatingNote }
        return hasLiveGames ? Self.liveUpdatingNote : nil
    }

    func game(id: String) -> Game? {
        games.first { $0.id == id }
    }

    /// The job behind `game`'s progress block: its latest analysis job while it is queued/processing, nil
    /// when it could not be loaded ("Waiting for the worker…", indeterminate bar).
    func activeJob(for game: Game) -> Job? {
        guard game.isBusy, let job = latestJobs[game.id], job.id == game.latestJobID else { return nil }
        return job
    }

    // MARK: - Loading

    /// Loads the list and the jobs of active games (07 §3.2). The newest call wins; an older one still
    /// running is cancelled.
    func refresh() async {
        refreshTask?.cancel()
        loadToken += 1
        let token = loadToken
        let task = Task { await performRefresh(token: token) }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRefresh(token: Int) async {
        guard let client = session.client else { return }
        isLoading = true
        defer { if token == loadToken { isLoading = false } }
        let loaded: [Game]
        do {
            loaded = try await client.games()
        } catch {
            guard token == loadToken, !Task.isCancelled else { return }
            if ServerSession.isCancellation(error) { return }
            self.error = session.report(error, from: client)
            // A retryable error is tried again in 10 s, also after a manual "Try again" (07 §3.2).
            if self.error?.isRetryable == true { wake.signal() }
            return
        }
        guard token == loadToken, !Task.isCancelled else { return }
        session.markReachable()

        // 07 §3.2 step 2: the job of every queued/processing game with a latest job, in parallel.
        let wanted = loaded.compactMap { game in game.isBusy ? game.latestJobID : nil }
        let results = await Self.loadJobs(wanted, client: client)
        guard token == loadToken, !Task.isCancelled else { return }
        var jobs: [String: Job] = [:]
        for result in results {
            switch result {
            case .success(let job):
                jobs[job.gameID] = job
            case .failure(let failure):
                // Ignored like the web, but 401/429 still trip the gate.
                if failure.stopsAllRequests { _ = session.report(failure, from: client) }
            }
        }
        games = loaded
        latestJobs = jobs
        error = nil
        hasLoaded = true
        lastLoadedAt = Date()
        if hasActiveGames || hasLiveGames { wake.signal() }
    }

    private nonisolated static func loadJobs(_ ids: [String], client: APIClient) async -> [Result<Job, APIError>] {
        await withTaskGroup(of: Result<Job, APIError>.self) { group in
            for id in ids {
                group.addTask {
                    do throws(APIError) {
                        return .success(try await client.job(id: id))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var results: [Result<Job, APIError>] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// The web's polling loop (07 §6 loop 1): loads at once, then 5 s after each load while a game is
    /// queued/processing and 10 s after a retryable error. Idle (nothing active, or stopped by an error
    /// that is not retryable, which stays for "Try again"), it waits until a load or `upsert` finds an
    /// active game. Returns when the task is cancelled or the session stops.
    ///
    /// Single-flight: several windows share the store (iPad scenes, Mac windows) and each list runs `poll()`.
    /// While one loop runs, another caller waits for it to end (its list went away), then takes over with
    /// its own loop, so the list is never loaded twice as often.
    func poll(sleeper: Sleeper = .live) async {
        while isPolling {
            pollEnded.reset()
            await pollEnded.wait()
            if Task.isCancelled { return }
        }
        isPolling = true
        defer {
            isPolling = false
            pollEnded.signal()
        }
        await runPollingLoop(sleeper: sleeper)
    }

    private func runPollingLoop(sleeper: Sleeper) async {
        await refresh()
        while !Task.isCancelled, session.isSignedIn {
            wake.reset()
            let interval: Duration?
            if let error {
                interval = error.isRetryable ? Self.retryInterval : nil
            } else if hasActiveGames {
                interval = Self.activeInterval
            } else {
                interval = hasLiveGames ? Self.liveInterval : nil
            }
            guard let interval else {
                // Woken by a load that found active games (or an upsert): wait the interval before the next.
                await wake.wait()
                continue
            }
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, session.isSignedIn else { return }
            await refresh()
        }
    }

    // MARK: - Changing

    /// Deletes a game (03 §2.1, 07 §3.7): `DELETE /api/games/{id}`, then reloads the list. A game that is
    /// already gone (404) counts as deleted. Errors are thrown for the caller to pass through
    /// `ServerSession.report(_:)`.
    func delete(_ gameID: String) async throws {
        guard let client = session.client else { throw ServerSessionError.notSignedIn }
        do {
            try await client.deleteGame(id: gameID)
        } catch {
            guard error.isNotFound else { throw error }
        }
        games.removeAll { $0.id == gameID }
        latestJobs[gameID] = nil
        didDelete(gameID)
        await refresh()
    }

    /// Puts a game the app just created or re-read into the list (replacing the one with its id; a new one
    /// goes first, as the newest). Wakes the poller when the game is queued/processing.
    func upsert(_ game: Game) {
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index] = game
        } else {
            games.insert(game, at: 0)
        }
        if let job = latestJobs[game.id], job.id != game.latestJobID { latestJobs[game.id] = nil }
        if game.isBusy || game.isLive { wake.signal() }
    }

    /// Keeps the latest job of a game the game page follows, so its card shows the same progress.
    func updateJob(_ job: Job) {
        guard job.kind != .report else { return }
        latestJobs[job.gameID] = job
    }

    /// Forgets everything (sign-out, another server).
    func reset() {
        refreshTask?.cancel()
        loadToken += 1
        games = []
        latestJobs = [:]
        error = nil
        hasLoaded = false
        isLoading = false
        lastLoadedAt = nil
    }

    // MARK: - SessionActivity

    func sessionDidStop() {
        refreshTask?.cancel()
        loadToken += 1
        isLoading = false
        wake.signal()
    }
}

// MARK: - Previews

extension GamesStore {
    /// A store showing `games` without any server (previews).
    static func preview(games: [Game], session: ServerSession = .preview()) -> GamesStore {
        let store = GamesStore(session: session)
        store.games = games
        store.hasLoaded = true
        return store
    }
}
