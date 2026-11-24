import Foundation
import Testing
@testable import BasketballScout

/// 02 §11 step by step against stubbed servers. Every scenario also checks the lockout rule: a check sends
/// at most ONE request with credentials (02 §4, 09 R6).
nonisolated struct ConnectionCheckerTests {
    static let now = Date(timeIntervalSince1970: 1_794_427_000)
    let checker = ConnectionChecker(session: StubSession.shared, now: { ConnectionCheckerTests.now })

    static let live = StubResponse.json(200, #"{"status":"ok"}"#)
    static let challenge = StubResponse.fixture(
        "err_401_no_auth.json", status: 401,
        headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#, "Cache-Control": "no-store"])

    /// A Basketball Scout server: live probe, 401 without credentials, `health` with the right ones.
    static func scoutServer(
        host: String = StubServer.uniqueLocalHost(), health: StubResponse = .fixture("health.json"),
        wrongPassword: StubResponse = ConnectionCheckerTests.challenge
    ) -> StubServer {
        StubServer(host: host) { request in
            switch request.path {
            case "/api/health/live": return live
            case "/api/health":
                guard let authorization = request.header("Authorization") else { return challenge }
                return authorization == TestServer.expectedAuthorization ? health : wrongPassword
            default: return .text(404, "<html>404 Not Found</html>")
            }
        }
    }

    private func check(
        _ server: StubServer, address: String? = nil, username: String = TestServer.credentials.username,
        password: String = TestServer.credentials.password, acceptPlainHTTP: Bool = true
    ) async throws -> ConnectionCheckResult {
        let address = try ServerAddress(userInput: address ?? "http://\(server.host):8000")
        return await checker.check(address: address, username: username, password: password, acceptPlainHTTP: acceptPlainHTTP)
    }

    private func credentialedRequests(_ server: StubServer) -> Int {
        server.requests.filter { $0.header("Authorization") != nil }.count
    }

    // MARK: Success

    @Test func signsInWithOneRequest() async throws {
        let server = Self.scoutServer()
        let result = try await check(server)
        let success = try #require(result.success)
        #expect(success.address.originString == "http://\(server.host):8000")
        #expect(success.signInRequired)
        let expectedHealth = try Fixture.decode(HealthStatus.self, "health.json")
        #expect(success.health == expectedHealth)
        #expect(result.health == success.health)
        #expect(success.title == "Connected")
        #expect(success.isTestedServerVersion)
        #expect(server.requests.map(\.path) == ["/api/health/live", "/api/health", "/api/health"])
        #expect(server.requests.map { $0.header("Authorization") } == [nil, nil, TestServer.expectedAuthorization])
        for request in server.requests {
            #expect(request.method == "GET")
            for name in APIClientRouteTests.forbiddenHeaders { #expect(request.header(name) == nil) }
        }
    }

    @Test func plainHTTPNeedsConsentBeforeThePasswordIsSent() async throws {
        let server = Self.scoutServer(host: StubServer.uniqueIPv4())
        let result = try await check(server, address: server.host + ":8000", acceptPlainHTTP: false)
        let typed = try ServerAddress(userInput: server.host + ":8000")
        #expect(result == .needsPlainHTTPConsent(typed))
        #expect(credentialedRequests(server) == 0)
        #expect(ConnectionChecker.PlainHTTPWarning.title == "Your password will be sent unencrypted")
        #expect(ConnectionChecker.PlainHTTPWarning.message
            == "Anyone on this network could read it. Ask IT for an https:// address (Tailscale or a certificate).")
        // After Continue.
        let accepted = try await check(server, address: server.host + ":8000", acceptPlainHTTP: true)
        #expect(accepted.success != nil)
        #expect(credentialedRequests(server) == 1)
    }

    @Test func httpsAndLoopbackNeedNoConsent() async throws {
        let https = Self.scoutServer(host: StubServer.uniqueDomain())
        let secure = try await check(https, address: https.host, acceptPlainHTTP: false)
        #expect(secure.success?.address.originString == "https://\(https.host)")

        let loopback = Self.scoutServer(host: "127.0.0.1")
        let local = try await check(loopback, address: "127.0.0.1:8000", acceptPlainHTTP: false)
        #expect(local.success != nil)
    }

    @Test func signInOffNeedsNoPassword() async throws {
        let health = try Fixture.text("health.json").replacingOccurrences(of: #""auth_enabled":true"#, with: #""auth_enabled":false"#)
        let server = StubServer { request in
            request.path == "/api/health/live" ? Self.live : .json(200, health)
        }
        let result = try await check(server, username: "", password: "", acceptPlainHTTP: false)
        let success = try #require(result.success)
        #expect(!success.signInRequired)
        #expect(!success.health.authEnabled)
        #expect(success.message == "This server doesn't use a password.")
        #expect(credentialedRequests(server) == 0)
        #expect(server.requests.count == 2)
    }

    @Test func degradedServersStillConnect() async throws {
        let server = Self.scoutServer(health: .fixture("health_degraded.json"))
        let success = try #require(try await check(server).success)
        #expect(success.isDegraded)
        #expect(success.title == "Connected, but the server needs attention")
        #expect(!success.health.notices.isEmpty)
    }

    // MARK: Step 1: finding the server

    /// install.sh without nginx: only port 8000 answers (02 §1.1, §11 step 1).
    @Test func triesPort8000WhenTheDefaultPortRefuses() async throws {
        let host = StubServer.uniqueIPv4()
        let inner = Self.scoutServer(host: "inner-\(host)")
        let server = StubServer(host: host) { request in
            request.url.port == nil ? .failure(URLError(.cannotConnectToHost)) : inner.respond(to: request)
        }
        let result = try await check(server, address: host)
        #expect(result.success?.address.originString == "http://\(host):8000")
        #expect(server.requests.first?.url.port == nil)
        #expect(server.requests.dropFirst().allSatisfy { $0.url.port == 8000 })
        #expect(credentialedRequests(server) == 1)
    }

    @Test func noPort8000RetryForAnExplicitPort() async throws {
        let server = StubServer(always: .failure(URLError(.cannotConnectToHost)))
        let address = "\(server.host):9000"
        let result = try await check(server, address: address)
        let typed = try ServerAddress(userInput: address)
        #expect(result == .failed(.network(.cannotConnect, typed)))
        #expect(server.requests.count == 1)
        let problem = try #require(result.problem)
        #expect(problem.title == "Nothing answered")
        #expect(problem.message == "No Basketball Scout server is answering at \(server.host):9000.")
        #expect(problem.isRetryable)
    }

    /// certbot `--redirect`: http → https on the same host is adopted (02 §1.1, §11 step 1).
    @Test func adoptsHTTPSAfterARedirect() async throws {
        let host = StubServer.uniqueLocalHost()
        let inner = Self.scoutServer(host: "inner-\(host)")
        let server = StubServer(host: host) { request in
            if request.url.scheme == "http" {
                return .empty(301, headers: ["Location": "https://\(host)/api/health/live"])
            }
            return inner.respond(to: request)
        }
        let result = try await check(server, address: "http://\(host)", acceptPlainHTTP: false)
        let success = try #require(result.success)
        #expect(success.address.originString == "https://\(host)")
        #expect(server.requests.filter { $0.url.scheme == "http" }.count == 1)
        #expect(server.requests.filter { $0.header("Authorization") != nil }.allSatisfy { $0.url.scheme == "https" })
        #expect(credentialedRequests(server) == 1)
    }

    @Test func aRedirectToAnotherHostMustBeConfirmed() async throws {
        let server = StubServer(always: .empty(302, headers: ["Location": "https://other.example.test/login"]))
        let result = try await check(server)
        let problem = try #require(result.problem)
        guard case .redirectedElsewhere(let from, let to) = problem else {
            Issue.record("expected redirectedElsewhere, got \(problem)")
            return
        }
        #expect(from.host == server.host)
        #expect(to.originString == "https://other.example.test")
        #expect(problem.suggestedAddress == to)
        #expect(problem.message == "\(server.host) sent the app on to https://other.example.test.")
        #expect(credentialedRequests(server) == 0)
    }

    @Test func neverFollowsADowngrade() async throws {
        let host = StubServer.uniqueIPv4()
        let server = StubServer(host: host, always: .empty(301, headers: ["Location": "http://\(host)/api/health/live"]))
        let result = try await check(server, address: "https://\(host)")
        let typed = try ServerAddress(userInput: "https://\(host)")
        #expect(result == .failed(.notBasketballScout(typed)))
        #expect(server.requests.count == 1)
    }

    /// nginx's answer to http on its TLS port: switch to https (02 §11 step 1).
    @Test func switchesToHTTPSOnAnHTTPSPort() async throws {
        let host = StubServer.uniqueIPv4()
        let inner = Self.scoutServer(host: "inner-\(host)")
        let server = StubServer(host: host) { request in
            if request.url.scheme == "http" {
                return .text(400, "<html><center>The plain HTTP request was sent to HTTPS port</center></html>")
            }
            return inner.respond(to: request)
        }
        let result = try await check(server, address: "http://\(host):8443")
        #expect(result.success?.address.originString == "https://\(host):8443")
    }

    @Test(arguments: [
        (StubResponse.text(404, "<html><center>nginx</center></html>"), "Not Basketball Scout at this address"),
        (StubResponse.text(502, "<html>502 Bad Gateway</html>"), "Basketball Scout isn't running"),
        (StubResponse.text(504, "<html>504 Gateway Time-out</html>"), "Basketball Scout isn't running"),
        (StubResponse.text(200, "<html>Welcome to the guest network</html>"), "Not a Basketball Scout server"),
        (StubResponse.json(200, #"{"hello":"world"}"#), "Not a Basketball Scout server"),
        (StubResponse.json(404, #"{"detail":"Not Found"}"#), "Not Basketball Scout at this address"),
    ])
    func somethingElseAnswers(response: StubResponse, title: String) async throws {
        let server = StubServer(always: response)
        let result = try await check(server)
        let problem = try #require(result.problem)
        #expect(problem.title == title)
        #expect(credentialedRequests(server) == 0)
    }

    @Test func notBasketballScoutMessages() throws {
        let address = try ServerAddress(userInput: "10.20.30.40")
        let here = ConnectionProblem.notBasketballScoutHere(address)
        #expect(here.message == "A web server answered at 10.20.30.40, but not Basketball Scout.")
        #expect(here.hint == "Try the server's name (for example scout.myschool.org) or ask IT for the exact address.")
        let other = ConnectionProblem.notBasketballScout(address)
        #expect(other.message == "Something answered at http://10.20.30.40, but it isn't Basketball Scout.")
        #expect(other.hint == "Check the address. On guest Wi-Fi you may need to sign in to the network first.")
        let down = ConnectionProblem.appNotRunning(address)
        #expect(down.message == "The server is up, but the Basketball Scout app on it isn't answering (it may be restarting).")
        #expect(down.hint == "Wait a minute and try again. IT: check basketball-scout-web.")
        #expect(down.isRetryable)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, NetworkProblem.timedOut),
        (.cannotFindHost, .cannotFindHost),
        (.serverCertificateUntrusted, .certificateUntrusted),
        (.serverCertificateHasBadDate, .certificateExpired),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.notConnectedToInternet, .offline),
        (.appTransportSecurityRequiresSecureConnection, .httpsRequired),
    ])
    func transportProblems(code: URLError.Code, problem: NetworkProblem) async throws {
        let server = StubServer(always: .failure(URLError(code)))
        let result = try await check(server)
        guard case .network(let found, let address)? = result.problem else {
            Issue.record("expected a network problem, got \(result)")
            return
        }
        #expect(found == problem)
        #expect(address.host == server.host)
    }

    @Test func deniedLocalNetworkAccess() async throws {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited)"])
        let server = StubServer(always: .failure(URLError(.notConnectedToInternet, userInfo: [NSUnderlyingErrorKey: underlying])))
        let problem = try #require(try await check(server).problem)
        #expect(problem.title == "Local Network access is off")
        #expect(problem.hint?.contains("Local Network") == true)
    }

    // MARK: Step 2: is it Basketball Scout?

    @Test func a401WithoutTheRealmIsNotBasketballScout() async throws {
        let server = StubServer { request in
            request.path == "/api/health/live"
                ? Self.live
                : .text(401, "Unauthorized", contentType: "text/plain", headers: ["WWW-Authenticate": #"Basic realm="Router""#])
        }
        let result = try await check(server)
        #expect(result.problem?.title == "Not a Basketball Scout server")
        #expect(credentialedRequests(server) == 0)
    }

    @Test func hostNotAllowed() async throws {
        let server = StubServer { request in
            request.path == "/api/health/live" ? Self.live : .fixture("err_403_host_not_allowed.json", status: 403)
        }
        let problem = try #require(try await check(server).problem)
        guard case .hostNotAllowed(let host, let message) = problem else {
            Issue.record("expected hostNotAllowed, got \(problem)")
            return
        }
        #expect(host == server.host)
        #expect(message.contains("SCOUT_ALLOWED_HOSTS"))
        #expect(problem.title == "This server doesn't accept that name")
        #expect(problem.message == "The server doesn't answer to “\(server.host)”.")
        #expect(problem.hint == "Use the server's IP address, or ask IT to add “\(server.host)” to SCOUT_ALLOWED_HOSTS and restart the web app.")
        #expect(problem.detail == message)
        #expect(credentialedRequests(server) == 0)
    }

    @Test func signInNotConfigured() async throws {
        let server = StubServer { request in
            request.path == "/api/health/live" ? Self.live : .fixture("err_503_auth_not_configured_no_credentials.json", status: 503)
        }
        let problem = try #require(try await check(server).problem)
        #expect(problem.title == "Sign-in isn't set up on the server")
        #expect(problem.message == "The server has no coaches' password yet.")
        #expect(problem.hint == "Ask IT to set SCOUT_AUTH_PASSWORD in .env and restart the web app.")
        #expect(problem.detail?.contains("SCOUT_AUTH_PASSWORD") == true)
        #expect(credentialedRequests(server) == 0)
    }

    @Test func lockedOutBeforeSigningIn() async throws {
        let server = StubServer { request in
            request.path == "/api/health/live"
                ? Self.live
                : .fixture("err_429_locked_out_no_credentials.json", status: 429, headers: ["Retry-After": "299"])
        }
        let problem = try #require(try await check(server).problem)
        #expect(problem == .throttled(retryAfter: 299, until: Self.now.addingTimeInterval(299)))
        #expect(problem.retryDate == Self.now.addingTimeInterval(299))
        #expect(problem.title == "Too many wrong passwords")
        #expect(problem.message == "Sign-in from this network is paused for about 5 minutes.")
        #expect(problem.hint?.contains("Devices that were already signed in keep working.") == true)
        #expect(!problem.isRetryable)
        #expect(credentialedRequests(server) == 0)
    }

    // MARK: Step 3: signing in

    @Test func wrongPasswordCountsOnce() async throws {
        let server = Self.scoutServer()
        let result = try await check(server, password: "wrong-password")
        #expect(result == .failed(.wrongCredentials))
        #expect(credentialedRequests(server) == 1)
        let problem = try #require(result.problem)
        #expect(problem.title == "Wrong username or password")
        #expect(problem.message == "The server didn't accept that username and password.")
        #expect(problem.hint == "Both are case-sensitive; the usual username is coach. 10 wrong tries in 5 minutes lock this network out for 5 minutes.")
        #expect(ConnectionProblem.lockoutWarningAfterWrongTries == 5)
    }

    @Test func lockedOutWhileSigningIn() async throws {
        let server = Self.scoutServer(wrongPassword: .fixture("err_429_auth_throttled.json", status: 429, headers: ["Retry-After": "60"]))
        let result = try await check(server, password: "tenth-wrong-password")
        #expect(result == .failed(.throttled(retryAfter: 60, until: Self.now.addingTimeInterval(60))))
        #expect(result.problem?.message == "Sign-in from this network is paused for about 1 minute.")
        #expect(credentialedRequests(server) == 1)
    }

    @Test func unreadableHealthIsAnUnsupportedVersion() async throws {
        let server = Self.scoutServer(health: .json(200, #"{"status":"ok","version":"9.0"}"#))
        let problem = try #require(try await check(server).problem)
        guard case .unsupportedServerVersion(let detail) = problem else {
            Issue.record("expected unsupportedServerVersion, got \(problem)")
            return
        }
        #expect(detail?.contains("Missing") == true)
        #expect(problem.title == "Server version not supported")
        #expect(problem.hint == "Ask IT to update the server (scripts/update.sh) or update the app.")
    }

    @Test func otherServerErrorsAreShownAsSent() async throws {
        let server = Self.scoutServer(health: .json(500, #"{"error":{"code":"INTERNAL_ERROR","title":"Unexpected error","message":"Something went wrong on the server.","hint":"Retry; if it keeps happening check the server logs.","retryable":true,"detail":null}}"#))
        let problem = try #require(try await check(server).problem)
        #expect(problem.title == "Unexpected error")
        #expect(problem.isRetryable)
        #expect(credentialedRequests(server) == 1)
    }

    /// Nothing that would only count as a wrong password is sent (02 §3.1, §4).
    @Test func refusesUnusableCredentialsWithoutSendingThem() async throws {
        let server = Self.scoutServer()
        #expect(try await check(server, username: "").problem == .missingUsername)
        #expect(try await check(server, username: "co:ach").problem == .invalidUsername)
        #expect(try await check(server, password: "").problem == .missingPassword)
        #expect(credentialedRequests(server) == 0)
        #expect(ConnectionProblem.missingPassword.title == "Enter the password")
        #expect(ConnectionProblem.invalidUsername.message == "A username can't contain a colon (:).")
    }

    @Test func parsesTheTypedAddressFirst() async {
        let result = await checker.check(addressText: "http://scout.myschool.org", username: "coach", password: "x")
        #expect(result == .failed(.invalidAddress(.httpsRequired(host: "scout.myschool.org"))))
        #expect(result.problem?.title == "This address needs https")
        let path = await checker.check(addressText: "10.20.30.40:8000/games", username: "coach", password: "x")
        #expect(path.problem?.suggestedAddress?.originString == "http://10.20.30.40:8000")
    }

    @Test func cancelledChecksStop() async throws {
        let server = Self.scoutServer()
        let address = try ServerAddress(userInput: "http://\(server.host):8000")
        let checker = self.checker
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await checker.check(address: address, username: "coach", password: "x", acceptPlainHTTP: true)
        }.value
        #expect(result == .failed(.cancelled))
        #expect(server.requests.isEmpty)
    }
}
