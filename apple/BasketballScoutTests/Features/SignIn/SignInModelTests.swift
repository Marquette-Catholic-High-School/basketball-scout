import Foundation
import Testing
@testable import BasketballScout

/// The sign-in form (02 §11; DESIGN §4): address parsing, the one-time plain-http question, wrong
/// passwords, the lockout, suggestions.
@MainActor
struct SignInModelTests {
    @Test func aNewFormSuggestsTheUsualUsername() {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = SignInModel(session: h.session)
        #expect(model.addressText.isEmpty)
        #expect(model.username == "coach")
        #expect(model.password.isEmpty)
        #expect(!model.canSubmit)
    }

    @Test func theFormIsPrefilledFromTheLastServer() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        h.session.signOut()

        let model = SignInModel(session: h.session)
        #expect(model.addressText == (try h.server.address).displayString)
        #expect(model.username == "coach")
        #expect(model.password.isEmpty)
    }

    @Test func anUnusableAddressIsExplainedWithoutSendingAnything() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = SignInModel(session: h.session)
        model.addressText = "http://scout.myschool.org"
        model.password = "pw"

        await model.signIn()

        #expect(model.problem?.title == "This address needs https")
        #expect(h.server.requests.isEmpty)
    }

    @Test func aPastedPageAddressOffersTheServerAddress() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = SignInModel(session: h.session)
        model.addressText = "http://\(h.server.host):8000/games/g_e934f8c21058"

        await model.signIn()

        let suggestion = try #require(model.suggestedAddress)
        #expect(suggestion.displayString == "http://\(h.server.host):8000")
        model.useSuggestedAddress()
        #expect(model.addressText == "http://\(h.server.host):8000")
        #expect(model.problem == nil)
    }

    @Test func plainHTTPIsAskedOnceThenSignsIn() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = SignInModel(session: h.session)
        model.addressText = "\(h.server.host):8000"
        model.password = SessionHarness.password

        await model.signIn()
        let address = try #require(model.plainHTTPConsentAddress)
        #expect(model.addressText == "http://\(h.server.host):8000")
        #expect(h.server.credentialedRequests.isEmpty)

        await model.continueOverPlainHTTP(to: address)
        #expect(model.plainHTTPConsentAddress == nil)
        #expect(h.session.isSignedIn)
        #expect(model.password.isEmpty)  // not kept in the form
    }

    @Test func aWrongPasswordIsClearedAndTheLockoutWarningComesAtTheFifth() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        h.server.setHealth(.json(401, try Fixture.data("err_401_wrong_password.json")))
        let model = SignInModel(session: h.session)
        model.addressText = "http://\(h.server.host):8000"

        for attempt in 1...ConnectionProblem.lockoutWarningAfterWrongTries {
            #expect(!model.showsLockoutWarning)
            model.password = "wrong-pw-\(attempt)"
            await model.signIn()
            if let address = model.plainHTTPConsentAddress { await model.continueOverPlainHTTP(to: address) }
            #expect(model.problem?.title == "Wrong username or password")
            #expect(model.password.isEmpty)
        }
        #expect(model.showsLockoutWarning)
    }

    @Test func aLockoutDisablesSignInUntilItEnds() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        h.server.setHealth(.json(429, try Fixture.data("err_429_auth_throttled.json"), headers: ["Retry-After": "60"]))
        let model = SignInModel(session: h.session)
        model.addressText = "http://\(h.server.host):8000"
        model.password = SessionHarness.password

        await model.signIn()
        if let address = model.plainHTTPConsentAddress { await model.continueOverPlainHTTP(to: address) }

        let until = try #require(model.lockedUntil)
        #expect(model.isLocked(at: until.addingTimeInterval(-1)))
        #expect(!model.isLocked(at: until.addingTimeInterval(1)))
        #expect(model.shownProblem == nil)  // the lockout has its own notice
        #expect(h.session.state == .locked(until: until))
    }

    @Test func aRejectedSavedPasswordEmptiesThePasswordField() async throws {
        let h = SessionHarness()
        defer { h.cleanUp() }
        try await h.signIn()
        let model = SignInModel(session: h.session)
        model.password = "typed-before"

        _ = h.session.report(APIError.unauthorized(nil))
        model.sync()

        #expect(model.password.isEmpty)
        #expect(model.passwordRejectedMessage == ServerSession.passwordRejectedMessage)
        #expect(model.addressText == (try h.server.address).displayString)
    }

    @Test func theLocalNetworkPermissionIsRecognised() {
        let h = SessionHarness()
        defer { h.cleanUp() }
        let model = SignInModel(session: h.session)
        #expect(!model.isLocalNetworkDenied)
        #expect(SignInSystemSettings.localNetworkURL != nil)
    }
}
