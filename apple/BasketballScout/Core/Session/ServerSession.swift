import Foundation
import Observation
import os

/// The connection to the coach's Basketball Scout server: sign-in, the saved server, the signed-in
/// `APIClient`, the server's health, and the lockout gate (DESIGN §4, §6 [C]; 02 §4, §10–§11; 09 R5–R10).
///
/// **Lockout gate (09 R6).** Ten wrong passwords in five minutes lock out a whole school network, and a
/// stale saved password plus a 3-second poller gets there in seconds. So EVERY area passes errors of
/// `APIClient` calls through `report(_:from:)` before showing them:
/// - 401 to a request that carried the password → everything stops (client dropped, pollers stopped,
///   uploads suspended, film requests cancelled), the saved password is deleted and the sign-in screen
///   asks for it again. Never retried.
/// - 429 `AUTH_THROTTLED` → everything stops until `Retry-After` has passed (countdown; remembered across
///   relaunches). A 429 `REPORT_RATE_LIMITED` is an ordinary error.
/// - 403 `HOST_NOT_ALLOWED`, 503 `AUTH_NOT_CONFIGURED` → everything stops; the sign-in screen explains it.
/// - Cancellations return nil; anything else is returned for display.
///
/// **One request before fan-out (02 §10 rule 2).** After launch (`restore()`), returning to the
/// foreground (`revalidate()`) and sign-in, ONE signed-in `GET /api/health` must pass before screens load
/// in parallel and uploads resume.
@Observable
final class ServerSession {
    typealias State = ServerSessionState

    /// Where the app stands. The UI shows the main screens only in `.signedIn`.
    private(set) var state: State = .signedOut
    /// The server in use, or the last one (to prefill the sign-in form).
    private(set) var profile: ServerProfile?
    /// The signed-in client; nil whenever requests must not be sent.
    private(set) var client: APIClient?
    /// The server's latest `GET /api/health`.
    private(set) var health: HealthStatus?
    /// When `health` was read.
    private(set) var healthCheckedAt: Date?
    /// Why the last explicit health check failed (System status shows it).
    private(set) var healthError: (any PresentableError)?
    /// A health check started by `refreshHealth()` is running.
    private(set) var isCheckingHealth = false
    /// Film streaming for the signed-in client (09 R11); a new one after every sign-in.
    private(set) var videoFactory: VideoAssetFactory?
    /// Court geometry (`GET /api/court/landmarks`): the same for every game, kept while signed in.
    private(set) var courtLandmarks: CourtLandmarks?
    /// Why the sign-in screen is shown when it is not a password or lockout matter (the server refused
    /// every request, or the saved password could not be read).
    private(set) var problem: (any PresentableError)?
    /// The launch or foreground check got no answer (offline, server restarting). The screens show their
    /// own errors; this clears once a signed-in request succeeds.
    private(set) var connectionProblem: (any PresentableError)?
    /// Something to tell the coach right after signing in (degraded server, demo mode…); the shell shows
    /// it once and sets it back to nil.
    var connectionNotice: ConnectionNotice?
    /// Wrong passwords in a row (02 §11 step 3: warn about the lockout from the 5th).
    private(set) var consecutiveWrongPasswords = 0
    /// Grows each time everything is stopped or a new client is made: work started under an older value
    /// must not continue.
    private(set) var generation = 0

    // MARK: - Hooks (set by AppModel)

    /// Everything was stopped: suspend uploads, close sheets.
    @ObservationIgnored var onStopAll: (ServerSessionStopReason) -> Void = { _ in }
    /// A signed-in request went through after a sign-in, launch or stop: resume uploads.
    @ObservationIgnored var onReachable: () -> Void = {}
    /// Signed in to a different server (or user) than before: forget that server's uploads and selection.
    @ObservationIgnored var onServerChanged: () -> Void = {}
    /// The coach signed out.
    @ObservationIgnored var onSignedOut: () -> Void = {}

    // MARK: - Dependencies

    @ObservationIgnored let profiles: ServerProfileStore
    @ObservationIgnored let httpSession: URLSession
    @ObservationIgnored private let keychain: any KeychainStore
    @ObservationIgnored private let cookieStorage: HTTPCookieStorage
    @ObservationIgnored private let lockouts: LockoutStore
    @ObservationIgnored private let analysisCache: AnalysisCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var activities: [ObjectIdentifier: WeakSessionActivity] = [:]
    @ObservationIgnored private var needsReachableSignal = true
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// Addresses the coach accepted plain http for in this run (saved in the profile once sign-in works),
    /// so a mistyped password does not bring the question back.
    @ObservationIgnored private var plainHTTPConsents: Set<ServerAddress> = []

    /// - Parameters:
    ///   - profiles: the saved server (UserDefaults).
    ///   - keychain: where the password lives (`SecurityKeychainStore`; tests use `InMemoryKeychainStore`).
    ///   - httpSession: the session every request uses (DESIGN §4; tests pass a stubbed one).
    ///   - cookieStorage: where the `scout_device` cookie lives (deleted on sign-out, 09 R7).
    ///   - lockouts: remembered 429 lockouts.
    ///   - analysisCache: cleared on sign-out and server change.
    ///   - now: the clock (lockout countdown).
    init(
        profiles: ServerProfileStore = ServerProfileStore(),
        keychain: any KeychainStore = SecurityKeychainStore(),
        httpSession: URLSession = ScoutHTTP.shared,
        cookieStorage: HTTPCookieStorage = .shared,
        lockouts: LockoutStore = LockoutStore(),
        analysisCache: AnalysisCache = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.keychain = keychain
        self.httpSession = httpSession
        self.cookieStorage = cookieStorage
        self.lockouts = lockouts
        self.analysisCache = analysisCache
        self.now = now
        self.profile = profiles.currentProfile ?? profiles.profiles.last
    }

    // MARK: - Facts

    var isSignedIn: Bool { state == .signedIn }

    /// The server's address in use (or last used).
    var address: ServerAddress? { client?.address ?? profile?.address }

    /// The password saved for the current server, to prefill the sign-in form after a lockout or a refusal
    /// (never after a 401: that one was deleted).
    func savedPassword() -> String? {
        guard let profile, profile.signInRequired else { return nil }
        return try? keychain.password(for: profile.keychainAccount)
    }

    /// The end of a lockout remembered for `address`, if it has not passed.
    func lockoutEnd(for address: ServerAddress) -> Date? {
        lockouts.until(for: address, now: now())
    }

    /// Something that sends requests on its own; it is stopped with everything else (09 R6).
    func register(_ activity: any SessionActivity) {
        activities = activities.filter { $0.value.object != nil }
        activities[ObjectIdentifier(activity)] = WeakSessionActivity(object: activity)
    }

    // MARK: - Sign in

    /// Runs the 02 §11 checklist for the typed server and, on success, saves the server, keeps the password
    /// in the Keychain and signs in.
    ///
    /// - `needsPlainHTTPConsent`: show `ConnectionChecker.PlainHTTPWarning`, then call again with
    ///   `acceptPlainHTTP: true` (asked once per server; the answer is saved).
    /// - `failed(.throttled)`: the session is `.locked(until:)`; nothing is sent until then.
    @discardableResult
    func signIn(address: ServerAddress, username: String, password: String, acceptPlainHTTP: Bool) async -> ConnectionCheckResult {
        if let until = lockouts.until(for: address, now: now()) {
            state = .locked(until: until)
            return .failed(.throttled(retryAfter: until.timeIntervalSince(now()), until: until))
        }
        if state.lockedUntil != nil { state = .signedOut }  // that lockout is over
        if acceptPlainHTTP { plainHTTPConsents.insert(address) }
        let accepted = acceptPlainHTTP || plainHTTPConsents.contains(address)
            || profiles.profiles.contains { $0.address == address && $0.acceptedPlainHTTPWarning }
        let checker = ConnectionChecker(session: httpSession, now: now)
        let result = await checker.check(address: address, username: username, password: password, acceptPlainHTTP: accepted)
        switch result {
        case .connected(let success):
            complete(success, typedAddress: address, username: username, password: password, acceptedPlainHTTP: accepted)
        case .needsPlainHTTPConsent:
            break
        case .failed(let problem):
            switch problem {
            case .throttled(_, let until):
                lockouts.set(until, for: address)
                state = .locked(until: until)
            case .wrongCredentials:
                consecutiveWrongPasswords += 1
            default:
                break
            }
        }
        return result
    }

    /// Saves and adopts a successful check.
    private func complete(
        _ success: ConnectionSuccess, typedAddress: ServerAddress, username: String, password: String, acceptedPlainHTTP: Bool
    ) {
        let address = success.address
        let previous = profiles.currentProfile ?? profile
        let serverChanged = previous.map { $0.address != address || $0.username != username } ?? false

        var saved = profiles.profile(for: address, username: username) ?? ServerProfile(address: address, username: username)
        saved.acceptedPlainHTTPWarning = saved.acceptedPlainHTTPWarning || (acceptedPlainHTTP && address.scheme == .http)
        saved.signInRequired = success.signInRequired
        saved.serverVersion = success.health.version
        saved.lastSignedInAt = now()
        for replaced in profiles.saveAsOnlyProfile(saved) {
            try? keychain.removePassword(for: replaced.keychainAccount)
            if replaced.address != address { ScoutHTTP.removeCookies(for: replaced.address, in: cookieStorage) }
        }
        if success.signInRequired {
            do {
                try keychain.setPassword(password, for: saved.keychainAccount)
            } catch {
                // Signed in all the same; the coach types the password again next launch.
                Self.logger.error("The password could not be saved in the Keychain")
            }
        } else {
            try? keychain.removePassword(for: saved.keychainAccount)
        }
        lockouts.clear(address)
        if typedAddress != address { lockouts.clear(typedAddress) }

        profile = saved
        problem = nil
        connectionProblem = nil
        consecutiveWrongPasswords = 0
        let credentials = success.signInRequired ? ServerCredentials(username: username, password: password) : .none
        adopt(APIClient(address: address, credentials: credentials, session: httpSession))
        updateHealth(success.health)
        connectionNotice = ConnectionNotice.isWorthShowing(success) ? ConnectionNotice(success: success) : nil
        if serverChanged {
            courtLandmarks = nil
            let cache = analysisCache
            Task { await cache.removeAll() }
            onServerChanged()
        }
        state = .signedIn
        Self.logger.notice("Signed in")
        markReachable()
    }

    // MARK: - Launch and foreground

    /// At launch: signs in again with the saved server and password through ONE `GET /api/health`
    /// (02 §10 rule 2). Without a saved password (or with a lockout still running) the sign-in screen is
    /// shown instead. Does nothing when already signed in.
    func restore() async {
        guard state == .signedOut, client == nil, restoreTask == nil else { return }
        let task = Task { await performRestore() }
        restoreTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        restoreTask = nil
    }

    /// Stops the launch check ("Cancel" on the connecting screen): the sign-in form is shown.
    func cancelChecking() {
        restoreTask?.cancel()
        if state == .checking { state = .signedOut }
    }

    private func performRestore() async {
        guard let saved = profiles.currentProfile else {
            profile = profiles.profiles.last
            return
        }
        profile = saved
        if let until = lockouts.until(for: saved.address, now: now()) {
            state = .locked(until: until)
            return
        }
        let credentials: ServerCredentials
        if saved.signInRequired {
            let password: String?
            do {
                password = try keychain.password(for: saved.keychainAccount)
            } catch {
                problem = error
                return
            }
            guard let password, !password.isEmpty else { return }
            credentials = ServerCredentials(username: saved.username, password: password)
        } else {
            credentials = .none
        }
        let candidate = APIClient(address: saved.address, credentials: credentials, session: httpSession)
        state = .checking
        do {
            let health = try await candidate.health()
            guard state == .checking else { return }
            adopt(candidate)
            updateHealth(health)
            state = .signedIn
            Self.logger.notice("Signed in with the saved password")
            markReachable()
        } catch {
            guard state == .checking else { return }
            if error.isCancellation || Task.isCancelled {
                state = .signedOut
            } else if error.stopsAllRequests {
                state = .signedOut
                applyGate(error, address: saved.address)
            } else {
                // No answer (offline, server restarting): the screens show their own errors and the first
                // signed-in request that goes through resumes the uploads.
                adopt(candidate)
                connectionProblem = error
                state = .signedIn
            }
        }
    }

    /// After the app returns to the foreground: ONE signed-in `GET /api/health` before the screens reload
    /// (02 §10 rule 2, 09 R29). Returns whether it went through; a 401/429 trips the gate.
    @discardableResult
    func revalidate() async -> Bool {
        guard state == .signedIn, let client else { return false }
        do {
            let health = try await client.health()
            updateHealth(health)
            markReachable()
            return true
        } catch {
            if let shown = report(error, from: client) { connectionProblem = shown }
            return false
        }
    }

    /// System status "Check again": reads `GET /api/health` (07 §3.8).
    func refreshHealth() async {
        guard let client else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        do {
            let health = try await client.health()
            updateHealth(health)
            healthError = nil
            markReachable()
        } catch {
            healthError = report(error, from: client)
        }
    }

    /// Keeps a health answer another screen read (the game page reads it on open and while a job is queued).
    func updateHealth(_ health: HealthStatus) {
        self.health = health
        healthCheckedAt = now()
    }

    /// Keeps the court geometry a game page read.
    func updateCourtLandmarks(_ landmarks: CourtLandmarks) {
        courtLandmarks = landmarks
    }

    /// A signed-in request went through: clears `connectionProblem` and, the first time after a sign-in,
    /// launch or stop, resumes the uploads (`onReachable`).
    func markReachable() {
        connectionProblem = nil
        guard needsReachableSignal, state == .signedIn, client != nil else { return }
        needsReachableSignal = false
        onReachable()
    }

    // MARK: - Sign out

    /// Signs out: stops everything, deletes the password from the Keychain and the server's cookies, and
    /// forgets cached analyses (09 R7, R44). The address and username stay to prefill the sign-in form;
    /// unfinished uploads continue after signing in to the same server again.
    func signOut() {
        restoreTask?.cancel()
        stopEverything(.signedOut)
        if let current = profiles.currentProfile ?? profile {
            try? keychain.removePassword(for: current.keychainAccount)
            ScoutHTTP.removeCookies(for: current.address, in: cookieStorage)
            profile = current
        }
        profiles.setCurrentProfile(nil)
        health = nil
        healthCheckedAt = nil
        healthError = nil
        courtLandmarks = nil
        problem = nil
        connectionProblem = nil
        connectionNotice = nil
        consecutiveWrongPasswords = 0
        state = .signedOut
        let cache = analysisCache
        Task { await cache.removeAll() }
        Self.logger.notice("Signed out")
        onSignedOut()
    }

    // MARK: - The lockout gate

    /// Applies the lockout gate to an error from a request (09 R6) and returns what to show, or nil when
    /// there is nothing to show (cancelled, or handled by returning to the sign-in screen).
    ///
    /// - Parameter reportingClient: the client that made the request. Errors of an older client (signed in
    ///   again since) do not trip the gate.
    @discardableResult
    func report(_ error: any Error, from reportingClient: APIClient? = nil) -> (any PresentableError)? {
        if Self.isCancellation(error) { return nil }
        guard let apiError = error as? APIError else {
            if let presentable = error as? any PresentableError { return presentable }
            return DisplayError.describing(error)
        }
        guard apiError.stopsAllRequests else { return apiError }
        guard let client else { return nil }  // already stopped
        if let reportingClient, reportingClient !== client { return nil }
        applyGate(apiError, address: client.address)
        return nil
    }

    /// Whether `error` is a cancellation (never shown).
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError { return apiError.isCancellation }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if let problem = error as? ConnectionProblem { return problem == .cancelled }
        return false
    }

    /// The text of the sign-in screen after a 401 to the saved password.
    static let passwordRejectedMessage =
        "Basketball Scout didn't accept the saved password. It may have been changed - type the current one to sign in again."

    private func applyGate(_ error: APIError, address: ServerAddress) {
        switch error {
        case .unauthorized:
            Self.logger.notice("401: stopped every request; asking for the password")
            stopEverything(.passwordRejected)
            if let current = profiles.currentProfile ?? profile {
                try? keychain.removePassword(for: current.keychainAccount)
            }
            consecutiveWrongPasswords += 1
            state = .needsPassword(message: Self.passwordRejectedMessage)
        case .throttled(let seconds, _):
            Self.logger.notice("429: stopped every request until the lockout ends")
            stopEverything(.throttled)
            let until = now().addingTimeInterval(max(1, seconds))
            lockouts.set(until, for: address)
            state = .locked(until: until)
        default:
            Self.logger.notice("The server refused every request: \(error.code, privacy: .public)")
            stopEverything(.refusedByServer)
            problem = error
            state = .signedOut
        }
    }

    /// Drops the client and stops every registered activity, the uploads and film requests.
    private func stopEverything(_ reason: ServerSessionStopReason) {
        generation += 1
        videoFactory?.invalidate()
        videoFactory = nil
        client = nil
        needsReachableSignal = true
        let current = activities.values.compactMap(\.object)
        activities = activities.filter { $0.value.object != nil }
        for activity in current { activity.sessionDidStop() }
        onStopAll(reason)
    }

    /// Makes `newClient` the signed-in client with a fresh film loader.
    private func adopt(_ newClient: APIClient) {
        videoFactory?.invalidate()
        generation += 1
        client = newClient
        needsReachableSignal = true
        videoFactory = VideoAssetFactory(client: newClient) { [weak self] error in
            _ = self?.report(error, from: newClient)
        }
    }

    static let logger = Logger(subsystem: "org.marquettecatholic.BasketballScout", category: "session")
}

// MARK: - Previews

extension ServerSession {
    /// A session for SwiftUI previews: shows `state` but never sends anything (no client, no Keychain,
    /// a throwaway settings suite).
    static func preview(state: State = .signedIn, health: HealthStatus? = nil, address: String = "http://10.20.30.40:8000") -> ServerSession {
        let suite = "org.marquettecatholic.BasketballScout.preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let session = ServerSession(
            profiles: ServerProfileStore(defaults: defaults, key: "preview.profiles"),
            keychain: InMemoryKeychainStore(),
            lockouts: LockoutStore(defaults: defaults, key: "preview.lockouts"))
        session.state = state
        session.health = health
        if let parsed = try? ServerAddress(userInput: address) {
            session.profile = ServerProfile(address: parsed, username: "coach", serverVersion: health?.version)
        }
        return session
    }
}
