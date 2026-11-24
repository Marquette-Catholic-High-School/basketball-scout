import Foundation
import Testing
@testable import BasketballScout

/// Signing in, out and again at launch (02 §11, §10 rule 2; DESIGN §4; 09 R5–R7).
@MainActor
struct ServerSessionTests {
    // MARK: - Sign in

    @Test func signInAsksOnceBeforeSendingThePasswordOverPlainHTTP() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let address = try h.server.address

        let first = await h.session.signIn(address: address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: false)
        guard case .needsPlainHTTPConsent(let asked) = first else {
            Issue.record("expected the plain-http question, got \(first)")
            return
        }
        #expect(asked == address)
        #expect(h.server.credentialedRequests.isEmpty)
        #expect(h.session.state == .signedOut)

        let second = await h.session.signIn(address: address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: true)
        #expect(second.success != nil)
        #expect(h.session.state == .signedIn)
        // Exactly one request carried the password (02 §11 step 3).
        #expect(h.server.credentialedRequests.count == 1)
        #expect(h.server.credentialedRequests.first?.path == "/api/health")
    }

    @Test func signInSavesTheServerAndKeepsThePasswordInTheKeychain() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let client = try await h.signIn()

        let profile = try #require(h.profiles.currentProfile)
        #expect(profile.address == (try h.server.address))
        #expect(profile.username == "coach")
        #expect(profile.acceptedPlainHTTPWarning)
        #expect(profile.signInRequired)
        #expect(profile.serverVersion == "0.1.0")
        #expect(h.keychain.items[try h.account] == SessionHarness.password)
        #expect(client.credentials == ServerCredentials(username: "coach", password: SessionHarness.password))
        #expect(h.session.health?.processor == "mock")
        #expect(h.session.videoFactory != nil)
        #expect(h.reachableCount == 1)
        // Demo mode (mock processor) is worth a notice after signing in (09 R43).
        #expect(h.session.connectionNotice != nil)
    }

    @Test func theSecondSignInDoesNotAskAboutPlainHTTPAgain() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.session.signOut()

        let again = await h.session.signIn(
            address: try h.server.address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: false)
        #expect(again.success != nil)
    }

    @Test func wrongPasswordsAreCounted() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        h.server.setHealth(.json(401, try Fixture.data("err_401_wrong_password.json")))
        for _ in 0..<ConnectionProblem.lockoutWarningAfterWrongTries {
            let result = await h.session.signIn(
                address: try h.server.address, username: "coach", password: "wrong-pw", acceptPlainHTTP: true)
            #expect(result.problem == .wrongCredentials)
        }
        #expect(h.session.consecutiveWrongPasswords == ConnectionProblem.lockoutWarningAfterWrongTries)
        #expect(h.session.state == .signedOut)
        #expect(h.keychain.items.isEmpty)

        h.server.setHealth(.fixture("health.json"))
        try await h.signIn()
        #expect(h.session.consecutiveWrongPasswords == 0)
    }

    @Test func aThrottledSignInLocksUntilRetryAfterAndSendsNothingMeanwhile() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        h.server.setHealth(.json(429, try Fixture.data("err_429_auth_throttled.json"), headers: ["Retry-After": "120"]))
        let start = h.clock.now
        let result = await h.session.signIn(
            address: try h.server.address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: true)
        guard case .throttled(_, let until)? = result.problem else {
            Issue.record("expected a lockout, got \(result)")
            return
        }
        #expect(until == start.addingTimeInterval(120))
        #expect(h.session.state == .locked(until: until))

        let sent = h.server.requests.count
        let again = await h.session.signIn(
            address: try h.server.address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: true)
        #expect(again.problem?.retryDate == until)
        #expect(h.server.requests.count == sent)

        // Once the lockout has passed, signing in works again.
        h.clock.advance(by: 121)
        h.server.setHealth(.fixture("health.json"))
        try await h.signIn()
        #expect(h.session.state == .signedIn)
    }

    // MARK: - Sign out

    @Test func signOutForgetsThePasswordAndTheCookiesButKeepsTheAddress() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let address = try h.server.address
        let cookie = try #require(HTTPCookie(properties: [
            .name: "scout_device", .value: "test-device-cookie", .domain: h.server.host, .path: "/",
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        #expect(HTTPCookieStorage.shared.cookies(for: address.origin)?.isEmpty == false)

        h.session.signOut()

        #expect(h.session.state == .signedOut)
        #expect(h.session.client == nil)
        #expect(h.session.videoFactory == nil)
        #expect(h.keychain.items.isEmpty)
        #expect(HTTPCookieStorage.shared.cookies(for: address.origin)?.isEmpty ?? true)
        #expect(h.profiles.currentProfile == nil)
        #expect(h.session.profile?.address == address)  // prefills the sign-in form
        #expect(h.stops == [.signedOut])
        #expect(h.signedOutCount == 1)
    }

    @Test func signingInToAnotherServerForgetsTheFirst() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let firstAccount = try h.account

        let other = SessionStubServer()
        let result = await h.session.signIn(
            address: try other.address, username: "coach", password: SessionHarness.password, acceptPlainHTTP: true)
        #expect(result.success != nil)
        #expect(h.serverChangedCount == 1)
        #expect(h.keychain.items[firstAccount] == nil)
        #expect(h.profiles.profiles.count == 1)
        #expect(h.profiles.currentProfile?.address == (try other.address))
    }

    // MARK: - Launch (02 §10 rule 2)

    @Test func restoreSignsInWithOneRequest() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try savedProfile(in: h)

        await h.session.restore()

        #expect(h.session.state == .signedIn)
        #expect(h.server.requests.count == 1)
        #expect(h.server.requests.first?.path == "/api/health")
        #expect(h.server.requests.first?.header("Authorization") != nil)
        #expect(h.reachableCount == 1)
        #expect(h.session.health != nil)
    }

    @Test func restoreWithARejectedPasswordAsksForItAndDeletesIt() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try savedProfile(in: h)
        h.server.setHealth(.json(401, try Fixture.data("err_401_wrong_password.json")))

        await h.session.restore()

        #expect(h.session.state == .needsPassword(message: ServerSession.passwordRejectedMessage))
        #expect(h.server.requests.count == 1)
        #expect(h.keychain.items.isEmpty)
        #expect(h.session.client == nil)
        #expect(h.reachableCount == 0)
    }

    @Test func restoreDuringALockoutSendsNothing() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try savedProfile(in: h)
        let until = h.clock.now.addingTimeInterval(200)
        h.lockouts.set(until, for: try h.server.address)

        await h.session.restore()

        #expect(h.session.state == .locked(until: until))
        #expect(h.server.requests.isEmpty)
    }

    @Test func restoreWithoutASavedPasswordShowsTheSignInForm() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try savedProfile(in: h, password: nil)

        await h.session.restore()

        #expect(h.session.state == .signedOut)
        #expect(h.session.profile?.address == (try h.server.address))
        #expect(h.server.requests.isEmpty)
    }

    @Test func restoreWithoutAnAnswerWaitsForTheFirstGoodRequestBeforeResumingUploads() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try savedProfile(in: h)
        h.server.setHealth(.failure(URLError(.timedOut)))

        await h.session.restore()

        #expect(h.session.state == .signedIn)
        #expect(h.session.connectionProblem != nil)
        #expect(h.reachableCount == 0)

        h.session.markReachable()
        #expect(h.session.connectionProblem == nil)
        #expect(h.reachableCount == 1)
        h.session.markReachable()
        #expect(h.reachableCount == 1)
    }

    @Test func revalidateRunsOneHealthCheck() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let before = h.server.count("GET", "/api/health")

        let passed = await h.session.revalidate()

        #expect(passed)
        #expect(h.server.count("GET", "/api/health") == before + 1)
    }

    @Test func refreshHealthKeepsTheAnswerAndTheError() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.server.setHealth(.fixture("health_degraded.json"))

        await h.session.refreshHealth()
        #expect(h.session.health?.status == .degraded)
        #expect(h.session.healthError == nil)

        h.server.setHealth(.html(502))
        await h.session.refreshHealth()
        #expect(h.session.healthError?.title == "Server unavailable")
        #expect(h.session.state == .signedIn)
    }

    // MARK: - Helpers

    private func savedProfile(in h: SessionHarness, password: String? = SessionHarness.password) throws {
        let profile = ServerProfile(address: try h.server.address, username: "coach", acceptedPlainHTTPWarning: true)
        h.profiles.saveAsOnlyProfile(profile)
        if let password { try h.keychain.setPassword(password, for: profile.keychainAccount) }
    }
}
