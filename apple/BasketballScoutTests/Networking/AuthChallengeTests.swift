import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// The server's 401 challenge on every request path (09 R5, R6). URLSession answers a 401 with
/// `WWW-Authenticate` by raising an authentication challenge; the app cancels it, so the request is sent
/// exactly once, and turns the cancellation back into the 401 (`ScoutTaskDelegate`). The stub raises the
/// challenge like CFNetwork does (its `failureResponse` is the 401, no body reaches the app); the real
/// re-send behaviour is checked against a socket in `AuthChallengeLoopbackTests`.
nonisolated struct AuthChallengeTests {
    // MARK: - The task delegate

    @Test func theDelegateCancelsTheServersChallengeAndKeepsTheAnswer() async throws {
        let delegate = ScoutTaskDelegate()
        let url = try #require(URL(string: "http://10.20.30.40:8000/api/games"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#]))
        let task = ScoutHTTP.shared.dataTask(with: url)
        defer { task.cancel() }

        let answer = await withCheckedContinuation { continuation in
            delegate.urlSession(
                ScoutHTTP.shared, task: task,
                didReceive: ScoutHTTPTests.challenge(NSURLAuthenticationMethodHTTPBasic, failureResponse: response)
            ) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        #expect(answer.0 == .cancelAuthenticationChallenge)
        #expect(answer.1 == nil)
        let rejection = try #require(delegate.rejection)
        #expect(rejection.status == 401)
        #expect(rejection.headers.hasBasketballScoutRealm)
        // The cancellation that follows is the server's 401; other failures stay what they are.
        #expect(delegate.apiError(for: URLError(.cancelled), url: url) == .unauthorized(nil))
        #expect(delegate.apiError(for: URLError(.timedOut), url: url).urlError?.code == .timedOut)
    }

    @Test func withoutAChallengeACancellationStaysACancellation() async throws {
        let delegate = ScoutTaskDelegate()
        let url = try #require(URL(string: "http://10.20.30.40:8000/api/games"))
        let task = ScoutHTTP.shared.dataTask(with: url)
        defer { task.cancel() }
        let answer = await withCheckedContinuation { continuation in
            delegate.urlSession(
                ScoutHTTP.shared, task: task, didReceive: ScoutHTTPTests.challenge(NSURLAuthenticationMethodServerTrust)
            ) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }
        #expect(answer == .performDefaultHandling)
        #expect(delegate.rejection == nil)
        #expect(delegate.apiError(for: URLError(.cancelled), url: url) == .cancelled)
        #expect(delegate.apiError(for: CancellationError(), url: url) == .cancelled)
    }

    @Test func aChallengeWithoutAnAnswerCountsAsA401() {
        let rejection = ScoutAuthChallenge.rejection(from: ScoutHTTPTests.challenge(NSURLAuthenticationMethodNTLM))
        #expect(rejection.status == 401)
        #expect(rejection.apiError.isAuthFailure)
    }

    @Test func theDelegateReportsUploadProgress() async throws {
        let sent = Mutex<[Int64]>([])
        let delegate = ScoutTaskDelegate { bytes, total in
            sent.withLock { $0.append(bytes) }
            #expect(total == 3000)
        }
        let task = ScoutHTTP.shared.dataTask(with: try #require(URL(string: "http://10.20.30.40:8000/api/uploads/u_1/chunk")))
        defer { task.cancel() }
        delegate.urlSession(ScoutHTTP.shared, task: task, didSendBodyData: 1000, totalBytesSent: 1000, totalBytesExpectedToSend: 3000)
        delegate.urlSession(ScoutHTTP.shared, task: task, didSendBodyData: 2000, totalBytesSent: 3000, totalBytesExpectedToSend: 3000)
        #expect(sent.withLock { $0 } == [1000, 3000])
    }

    // MARK: - Through the client (every route)

    @Test func aChallengedRequestIsSentOnceAndIsA401() async throws {
        let server = StubServer(always: .basicChallenge)
        let client = try TestServer.client(for: server)

        let error = await #expect(throws: APIError.self) { try await client.games() }

        #expect(error == .unauthorized(nil))
        #expect(error?.isAuthFailure == true)
        #expect(error?.stopsAllRequests == true)
        #expect(server.requests.count == 1)
    }

    @Test func aChallengedMutationIsSentOnce() async throws {
        let server = StubServer(always: .basicChallenge)
        let client = try TestServer.client(for: server)

        let error = await #expect(throws: APIError.self) { try await client.cancelJob(id: "j_303a5ba171e4") }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.map(\.method) == ["POST"])
    }

    @Test func aChallengedChunkIsSentOnce() async throws {
        let server = StubServer(always: .basicChallenge)
        let client = try TestServer.client(for: server)

        let error = await #expect(throws: APIError.self) {
            try await client.uploadChunk(uploadID: "u_4b596795629f", offset: 0, data: Data(repeating: 7, count: 2000)) { _, _ in }
        }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.count == 1)
        #expect(server.lastRequest?.method == "PUT")
    }

    @Test func aChallengedDownloadIsSentOnce() async throws {
        let server = StubServer(always: .basicChallenge)
        let client = try TestServer.client(for: server)

        let error = await #expect(throws: APIError.self) { try await client.downloadTimelineCSV(gameID: "g_e934f8c21058") }

        #expect(error?.isAuthFailure == true)
        #expect(server.requests.count == 1)
    }

    @Test func aRealCancellationStaysACancellation() async throws {
        let server = StubServer(always: .basicChallenge)
        let client = try TestServer.client(for: server)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.games()
        }.result
        #expect(throws: APIError.cancelled) { try result.get() }
        #expect(server.requests.isEmpty)
    }

    // MARK: - The connection check (02 §11)

    /// Step 2 recognises the server by the realm of the challenge (the body does not reach the app); step 3's
    /// wrong password is one request and "Wrong username or password".
    @Test func theCheckReadsTheRealmAndCountsAWrongPasswordOnce() async throws {
        let server = StubServer { request in
            switch request.path {
            case "/api/health/live": return ConnectionCheckerTests.live
            case "/api/health":
                guard request.header("Authorization") == TestServer.expectedAuthorization else { return .basicChallenge }
                return .fixture("health.json")
            default: return .text(404, "<html>404 Not Found</html>")
            }
        }
        let checker = ConnectionChecker(session: StubSession.shared)
        let address = try ServerAddress(userInput: "http://\(server.host):8000")

        let wrong = await checker.check(address: address, username: "coach", password: "wrong-password-1", acceptPlainHTTP: true)
        #expect(wrong == .failed(.wrongCredentials))
        #expect(server.requests.map(\.path) == ["/api/health/live", "/api/health", "/api/health"])
        #expect(server.requests.filter { $0.header("Authorization") != nil }.count == 1)

        let right = await checker.check(
            address: address, username: TestServer.credentials.username, password: TestServer.credentials.password,
            acceptPlainHTTP: true)
        #expect(right.success?.signInRequired == true)
    }

    @Test func aChallengeFromAnotherRealmIsNotBasketballScout() async throws {
        let server = StubServer { request in
            request.path == "/api/health/live"
                ? ConnectionCheckerTests.live
                : .challenge(status: 401, headers: ["WWW-Authenticate": #"Basic realm="Router""#])
        }
        let checker = ConnectionChecker(session: StubSession.shared)
        let result = await checker.check(
            address: try ServerAddress(userInput: "http://\(server.host):8000"), username: "coach", password: "wrong-password-2",
            acceptPlainHTTP: true)
        #expect(result.problem?.title == "Not a Basketball Scout server")
        #expect(server.requests.filter { $0.header("Authorization") != nil }.isEmpty)
    }
}
