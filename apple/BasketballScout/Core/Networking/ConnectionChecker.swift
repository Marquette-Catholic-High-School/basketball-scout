import Foundation

/// The 02 §11 connection checklist: find the server, make sure it is Basketball Scout, then sign in with
/// ONE request.
///
/// 1. `GET /api/health/live` without credentials (10 s). Same-host redirects are followed by hand
///    (certbot's http → https is adopted; never a downgrade); a plain-http address without a port that
///    refuses the connection is tried once more on `:8000` (install without nginx); nginx's "plain HTTP
///    request was sent to HTTPS port" switches to https. A redirect to another host stops with
///    `redirectedElsewhere` so the coach can confirm it.
/// 2. `GET /api/health` without credentials: a 401 with the "Basketball Scout" realm confirms the server
///    and that it wants a password; a 200 with `auth_enabled: false` means sign-in is off (done).
///    `HOST_NOT_ALLOWED`, `AUTH_THROTTLED` and `AUTH_NOT_CONFIGURED` stop here.
/// 3. Plain http to another machine needs the coach's consent first (`needsPlainHTTPConsent`). Then ONE
///    `GET /api/health` with `Authorization`, never repeated and never sent in parallel.
///
/// Requests without credentials never count toward the lockout (02 §4), so a check adds at most one
/// counted failure: the step 3 request.
nonisolated struct ConnectionChecker: Sendable {
    /// The server version this app was built and tested against (02 §11 step 4).
    static let testedServerVersion = "0.1.0"
    /// Redirects followed in step 1 before giving up.
    static let maximumRedirects = 3

    /// The warning before a password goes over plain http (02 §11; README "Security").
    nonisolated enum PlainHTTPWarning {
        static let title = "Your password will be sent unencrypted"
        static let message = "Anyone on this network could read it. Ask IT for an https:// address (Tailscale or a certificate)."
        static let continueTitle = "Continue"
        static let cancelTitle = "Cancel"
    }

    let session: URLSession
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - session: the app's session (tests pass one with a stub protocol).
    ///   - now: the clock for the lockout countdown.
    init(session: URLSession = ScoutHTTP.shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// Runs the checklist with the shared session.
    static func check(
        address: ServerAddress, username: String, password: String, acceptPlainHTTP: Bool = false
    ) async -> ConnectionCheckResult {
        await ConnectionChecker().check(
            address: address, username: username, password: password, acceptPlainHTTP: acceptPlainHTTP)
    }

    /// Parses `addressText` (step 0), then runs the checklist.
    func check(
        addressText: String, username: String, password: String, acceptPlainHTTP: Bool = false
    ) async -> ConnectionCheckResult {
        do {
            let address = try ServerAddress(userInput: addressText)
            return await check(address: address, username: username, password: password, acceptPlainHTTP: acceptPlainHTTP)
        } catch {
            return .failed(.invalidAddress(error))
        }
    }

    /// Runs steps 1–3 for `address`.
    /// - Parameter acceptPlainHTTP: the coach accepted the unencrypted-password warning for this address.
    func check(
        address: ServerAddress, username: String, password: String, acceptPlainHTTP: Bool = false
    ) async -> ConnectionCheckResult {
        let reachable: ServerAddress
        switch await findServer(at: address) {
        case .success(let found): reachable = found
        case .failure(let problem): return .failed(problem)
        }

        switch await identify(reachable) {
        case .signInRequired:
            break
        case .signInOff(let health):
            return .connected(ConnectionSuccess(address: reachable, health: health, signInRequired: false))
        case .failure(let problem):
            return .failed(problem)
        }

        // Nothing below may send a password the server would count as wrong without need.
        guard !username.isEmpty else { return .failed(.missingUsername) }
        let credentials = ServerCredentials(username: username, password: password)
        guard credentials.hasValidUsername else { return .failed(.invalidUsername) }
        guard !password.isEmpty else { return .failed(.missingPassword) }
        if reachable.needsPlainHTTPWarning && !acceptPlainHTTP { return .needsPlainHTTPConsent(reachable) }
        return await signIn(at: reachable, with: credentials)
    }

    // MARK: - Step 1: is something there?

    private func findServer(at start: ServerAddress) async -> Result<ServerAddress, ConnectionProblem> {
        var address = start
        var redirects = 0
        var triedPort8000 = false
        var triedHTTPS = false
        while true {
            let outcome = await fetch("/api/health/live", at: address, credentials: nil, timeout: APIClient.Timeout.probe)
            switch outcome {
            case .cancelled:
                return .failure(.cancelled)
            case .transport(let error):
                // 02 §11: an install without nginx answers on port 8000 only.
                if error.code == .cannotConnectToHost, address.scheme == .http, address.port == nil, !triedPort8000,
                   let next = try? address.with(scheme: .http, port: 8000) {
                    triedPort8000 = true
                    address = next
                    continue
                }
                return .failure(.network(NetworkProblem(error), address))
            case .answer(let status, let headers, let body):
                if status == 200 {
                    if (try? ScoutJSON.decode(HealthLive.self, from: body))?.isOK == true { return .success(address) }
                    return .failure(.notBasketballScout(address))
                }
                if (300..<400).contains(status), let location = headers.location {
                    guard redirects < Self.maximumRedirects else { return .failure(.notBasketballScout(address)) }
                    redirects += 1
                    switch Self.redirectTarget(location, from: address) {
                    case .sameHost(let next):
                        address = next
                        continue
                    case .otherHost(let target):
                        return .failure(.redirectedElsewhere(from: address, to: target))
                    case .unusable:
                        return .failure(.notBasketballScout(address))
                    }
                }
                let isServerJSON = APIError.serverEnvelope(in: body) != nil
                if status == 400, address.scheme == .http, !triedHTTPS, !isServerJSON,
                   String(decoding: body, as: UTF8.self).lowercased().contains("plain http request was sent to https port"),
                   let next = try? address.with(scheme: .https, port: address.effectivePort) {
                    triedHTTPS = true
                    address = next
                    continue
                }
                if status == 404, !isServerJSON { return .failure(.notBasketballScoutHere(address)) }
                if (502...504).contains(status), !isServerJSON { return .failure(.appNotRunning(address)) }
                return .failure(.notBasketballScout(address))
            }
        }
    }

    private nonisolated enum RedirectTarget {
        case sameHost(ServerAddress)
        case otherHost(ServerAddress)
        case unusable
    }

    /// Where a redirect from `address` leads: the same host on an allowed scheme and port (never https →
    /// http), another host (the coach must confirm), or nowhere usable.
    private static func redirectTarget(_ location: String, from address: ServerAddress) -> RedirectTarget {
        guard let url = URL(string: location, relativeTo: address.origin)?.absoluteURL,
              let schemeName = url.scheme?.lowercased(), let scheme = ServerAddress.Scheme(rawValue: schemeName),
              let host = url.host(percentEncoded: true), !host.isEmpty,
              let target = try? ServerAddress(scheme: scheme, host: host, port: url.port)
        else { return .unusable }
        guard target.host == address.host else { return .otherHost(target) }
        if address.isHTTPS && !target.isHTTPS { return .unusable }
        return target == address ? .unusable : .sameHost(target)
    }

    // MARK: - Step 2: is it Basketball Scout, and does it want a password?

    private nonisolated enum Identity {
        case signInRequired
        case signInOff(HealthStatus)
        case failure(ConnectionProblem)
    }

    private func identify(_ address: ServerAddress) async -> Identity {
        switch await fetch("/api/health", at: address, credentials: nil, timeout: Self.signInTimeout) {
        case .cancelled:
            return .failure(.cancelled)
        case .transport(let error):
            return .failure(.network(NetworkProblem(error), address))
        case .answer(let status, let headers, let body):
            if status == 401 {
                let envelope = APIError.serverEnvelope(in: body)
                if headers.hasBasketballScoutRealm || envelope?.error.code == ErrorCode.authRequired { return .signInRequired }
                return .failure(.notBasketballScout(address))
            }
            if status == 200 {
                do {
                    let health = try ScoutJSON.decode(HealthStatus.self, from: body)
                    return health.authEnabled ? .signInRequired : .signInOff(health)
                } catch {
                    return .failure(.unsupportedServerVersion(detail: APIError.describe(error)))
                }
            }
            return .failure(problem(status: status, headers: headers, body: body, address: address))
        }
    }

    // MARK: - Step 3: sign in (one request)

    private func signIn(at address: ServerAddress, with credentials: ServerCredentials) async -> ConnectionCheckResult {
        switch await fetch("/api/health", at: address, credentials: credentials, timeout: Self.signInTimeout) {
        case .cancelled:
            return .failed(.cancelled)
        case .transport(let error):
            return .failed(.network(NetworkProblem(error), address))
        case .answer(let status, let headers, let body):
            if status == 200 {
                do {
                    let health = try ScoutJSON.decode(HealthStatus.self, from: body)
                    return .connected(ConnectionSuccess(address: address, health: health, signInRequired: true))
                } catch {
                    return .failed(.unsupportedServerVersion(detail: APIError.describe(error)))
                }
            }
            if status == 401 { return .failed(.wrongCredentials) }
            return .failed(problem(status: status, headers: headers, body: body, address: address))
        }
    }

    /// Steps 2–3: the middleware refusals by code, the server's other errors, the proxy's 502–504, or
    /// "not Basketball Scout".
    private func problem(status: Int, headers: HTTPHeaders, body: Data, address: ServerAddress) -> ConnectionProblem {
        guard let envelope = APIError.serverEnvelope(in: body) else {
            if (502...504).contains(status) { return .appNotRunning(address) }
            return .notBasketballScout(address)
        }
        switch envelope.error.code {
        case ErrorCode.hostNotAllowed:
            return .hostNotAllowed(host: address.host, serverMessage: envelope.error.message)
        case ErrorCode.authNotConfigured:
            return .signInNotConfigured(serverMessage: envelope.error.message)
        case ErrorCode.authThrottled where status == 429:
            let seconds = RetryAfter.seconds(from: headers.retryAfter, now: now()) ?? APIError.defaultThrottleSeconds
            return .throttled(retryAfter: seconds, until: now().addingTimeInterval(seconds))
        default:
            return .serverError(APIError.from(status: status, headers: headers, body: body))
        }
    }

    // MARK: - Transport

    /// Steps 2 and 3 wait a little longer than the probe: the first password check after a server restart
    /// runs PBKDF2 (02 §3.1).
    static let signInTimeout: TimeInterval = 30

    private nonisolated enum Outcome {
        case answer(status: Int, headers: HTTPHeaders, body: Data)
        case transport(URLError)
        case cancelled
    }

    /// One GET of `path` on `address`; `Authorization` only when `credentials` are given. A 401 whose challenge
    /// was cancelled (`ScoutAuthChallenge`: the request is sent exactly once) comes back as that answer, with
    /// its headers (the realm) and without a body.
    private func fetch(_ path: String, at address: ServerAddress, credentials: ServerCredentials?, timeout: TimeInterval) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let url = URL(string: address.originString + path) ?? address.origin
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = credentials?.authorizationHeaderValue {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let delegate = ScoutTaskDelegate()
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { return .transport(URLError(.badServerResponse)) }
            return .answer(status: http.statusCode, headers: HTTPHeaders(http), body: data)
        } catch {
            let failure = APIError.from(transportError: error, url: url)
            if failure.isCancellation, let rejection = delegate.rejection {
                return .answer(status: rejection.status, headers: rejection.headers, body: Data())
            }
            switch failure {
            case .transport(let urlError): return .transport(urlError)
            case .cancelled: return .cancelled
            default: return .transport(URLError(.unknown))
            }
        }
    }
}
