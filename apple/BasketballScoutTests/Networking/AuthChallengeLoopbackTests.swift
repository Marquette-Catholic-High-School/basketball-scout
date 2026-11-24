import AVFoundation
import Foundation
import Testing
@testable import BasketballScout

/// The server's 401 challenge over a real socket (09 R5, R6). With `.performDefaultHandling` CFNetwork sent
/// every challenged request twice (once more on a new connection), so each wrong password counted twice
/// toward the lockout (10 failures in 5 minutes per address). Each request path must reach the server
/// exactly once per 401 and report it as `unauthorized`.
///
/// Runs where the test host may listen on a port: the iOS Simulator. The sandboxed Mac app may only connect
/// out, so on the Mac the suite is skipped (`RealServerAuthTests` covers a running server there).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: LoopbackHTTPServer.canListen))
struct AuthChallengeLoopbackTests {
    /// The app's session configuration and delegate, without stubs.
    private static let session = ScoutHTTP.makeSession(configuration: ScoutHTTP.makeConfiguration())
    /// Not the server's password (it answers every credentialed request with 401).
    private static let wrong = ServerCredentials(username: "coach", password: "loopback-wrong-pw-1")

    /// Errors the film factory reported on the main actor.
    private final class Reports {
        var errors: [APIError] = []
    }

    /// A Basketball Scout server that refuses every password: live probe 200, everything else the 401 challenge.
    private func refusingServer() async throws -> LoopbackHTTPServer {
        try await LoopbackHTTPServer.start { request in
            request.path == "/api/health/live" ? .json(200, #"{"status":"ok"}"#) : .challenge
        }
    }

    private func client(_ server: LoopbackHTTPServer) throws -> APIClient {
        APIClient(address: try ServerAddress(userInput: server.addressText), credentials: Self.wrong, session: Self.session)
    }

    @Test func aGETIsSentOnce() async throws {
        let server = try await refusingServer()
        defer { server.stop() }

        let error = await #expect(throws: APIError.self) { try await client(server).games() }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.map(\.path) == ["/api/games"])
        #expect(server.requests.first?.header("Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test func aChunkPUTIsSentOnce() async throws {
        let server = try await refusingServer()
        defer { server.stop() }

        let error = await #expect(throws: APIError.self) {
            try await client(server).uploadChunk(uploadID: "u_4b596795629f", offset: 0, data: Data(repeating: 7, count: 4096)) { _, _ in }
        }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.map(\.method) == ["PUT"])
    }

    @Test func aDownloadIsSentOnce() async throws {
        let server = try await refusingServer()
        defer { server.stop() }

        let error = await #expect(throws: APIError.self) { try await client(server).downloadTimelineCSV(gameID: "g_e934f8c21058") }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.count == 1)
    }

    /// 02 §11: the check finds the server (realm in step 2) and a wrong password costs ONE counted request.
    @Test func aWrongPasswordCountsOnce() async throws {
        let server = try await refusingServer()
        defer { server.stop() }
        let checker = ConnectionChecker(session: Self.session)

        let result = await checker.check(
            address: try ServerAddress(userInput: server.addressText), username: Self.wrong.username, password: Self.wrong.password)

        #expect(result == .failed(.wrongCredentials))
        #expect(server.requests.map(\.path) == ["/api/health/live", "/api/health", "/api/health"])
        #expect(server.requests.filter { $0.header("Authorization") != nil }.count == 1)
    }

    /// The film's range requests (09 R11): the first 401 is reported once and nothing more is sent.
    @Test func aFilmRequestIsSentOnce() async throws {
        let server = try await refusingServer()
        defer { server.stop() }
        let reports = Reports()
        let factory = VideoAssetFactory(client: try client(server)) { reports.errors.append($0) }

        let asset = factory.makeAsset(gameID: "g_e934f8c21058", filmFileName: "Test Film.mp4")
        await #expect(throws: (any Error).self) { try await asset.load(.duration) }
        try await waitUntil("the error report") { !reports.errors.isEmpty }

        #expect(reports.errors.count == 1)
        #expect(reports.errors.first?.isAuthFailure == true)
        #expect(factory.stopError?.isAuthFailure == true)
        #expect(server.requests.count == 1)
    }
}
