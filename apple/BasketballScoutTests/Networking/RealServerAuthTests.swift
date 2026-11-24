import Foundation
import Testing
@testable import BasketballScout

/// Wrong passwords against a running Basketball Scout server: not part of the normal run (skipped unless
/// `SCOUT_ITEST_SERVER` is set, e.g. `TEST_RUNNER_SCOUT_ITEST_SERVER=http://127.0.0.1:8793` for xcodebuild).
///
/// It sends exactly two wrong passwords: one connection check and one API call. The server's log must then
/// show two "Failed sign-in" lines and one 401 per request (before the challenge fix CFNetwork sent each
/// request twice, so each wrong password counted twice toward the lockout). No real password is used.
@MainActor
@Suite(.enabled(if: RealServerEnvironment.serverText != nil), .serialized)
struct RealServerAuthTests {
    private func address() throws -> ServerAddress {
        try ServerAddress(userInput: try #require(RealServerEnvironment.serverText))
    }

    @Test func aWrongPasswordInTheConnectionCheck() async throws {
        let checker = ConnectionChecker(session: ScoutHTTP.makeSession(configuration: ScoutHTTP.makeConfiguration()))
        let result = await checker.check(
            address: try address(), username: "coach", password: "itest-wrong-password-1", acceptPlainHTTP: true)
        #expect(result == .failed(.wrongCredentials))
    }

    @Test func aWrongPasswordOnAnAPICall() async throws {
        let client = APIClient(
            address: try address(), credentials: ServerCredentials(username: "coach", password: "itest-wrong-password-2"),
            session: ScoutHTTP.makeSession(configuration: ScoutHTTP.makeConfiguration()))
        let error = await #expect(throws: APIError.self) { try await client.games() }
        #expect(error == .unauthorized(nil))
    }
}

/// The running server the opt-in tests use (`SCOUT_ITEST_SERVER`), or nil.
nonisolated enum RealServerEnvironment {
    static var serverText: String? {
        ProcessInfo.processInfo.environment["SCOUT_ITEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
