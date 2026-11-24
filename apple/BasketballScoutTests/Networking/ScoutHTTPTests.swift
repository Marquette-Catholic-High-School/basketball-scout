import Foundation
import Testing
@testable import BasketballScout

/// DESIGN §4 session configuration and the delegate's challenge and redirect rules (09 R5, R7).
nonisolated struct ScoutHTTPTests {
    @Test func configurationFollowsTheDesign() {
        let configuration = ScoutHTTP.makeConfiguration()
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage === HTTPCookieStorage.shared)
        #expect(configuration.httpCookieAcceptPolicy == .always)
        #expect(configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(!configuration.waitsForConnectivity)
        // No extra headers: in particular no Origin/Referer/Sec-Fetch-Site/X-Forwarded-Host (02 §1.3).
        #expect((configuration.httpAdditionalHeaders ?? [:]).isEmpty)
    }

    @Test func sharedSessionUsesTheDelegate() {
        #expect(ScoutHTTP.shared.delegate is ScoutSessionDelegate)
        #expect(ScoutHTTP.shared.configuration.urlCredentialStorage == nil)
        #expect(ScoutHTTP.shared.configuration.urlCache == nil)
    }

    /// 09 R5/R6: the server's 401 challenge is cancelled (any other answer makes CFNetwork send the request a
    /// second time, so each wrong password would count twice toward the lockout); server trust keeps the
    /// system's default handling. The session delegate is the fallback for tasks without their own delegate.
    @Test func theServersChallengeIsCancelledAndServerTrustKeepsTheDefault() async throws {
        let delegate = ScoutSessionDelegate()
        let task = ScoutHTTP.shared.dataTask(with: try #require(URL(string: "http://10.20.30.40:8000/api/health")))
        defer { task.cancel() }
        for method in [
            NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault,
        ] {
            let answer = await withCheckedContinuation { continuation in
                delegate.urlSession(ScoutHTTP.shared, task: task, didReceive: Self.challenge(method)) { disposition, credential in
                    continuation.resume(returning: (disposition, credential))
                }
            }
            #expect(answer.0 == .cancelAuthenticationChallenge, "\(method)")
            #expect(answer.1 == nil)
        }
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate] {
            let answer = await withCheckedContinuation { continuation in
                delegate.urlSession(ScoutHTTP.shared, task: task, didReceive: Self.challenge(method)) { disposition, credential in
                    continuation.resume(returning: (disposition, credential))
                }
            }
            #expect(answer.0 == .performDefaultHandling, "\(method)")
            #expect(answer.1 == nil)
        }
    }

    /// A proxy's challenge does not count toward the server's lockout: default handling.
    @Test func aProxysChallengeKeepsTheDefault() {
        let space = URLProtectionSpace(
            proxyHost: "proxy.example.test", port: 3128, type: NSURLProtectionSpaceHTTPProxy, realm: "Proxy",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
            sender: ChallengeSender())
        #expect(!ScoutAuthChallenge.isServerAuthentication(challenge))
        #expect(ScoutAuthChallenge.disposition(for: challenge) == .performDefaultHandling)
    }

    /// No session-level challenge method: connection-level challenges (NTLM, Negotiate, server trust) then
    /// reach the task level, where the task's delegate keeps the 401 for its caller.
    @Test func challengesAreAnsweredPerTask() {
        let delegate = ScoutSessionDelegate()
        #expect(!delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))))
        #expect(delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))))
    }

    static func challenge(_ method: String, failureResponse: URLResponse? = nil) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "10.20.30.40", port: 8000, protocol: "http", realm: "Basketball Scout", authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: failureResponse,
            error: nil, sender: ChallengeSender())
    }

    /// Redirects are never followed: a 301 would turn a POST into a GET and could carry the password away.
    @Test func redirectsAreRefused() async throws {
        let delegate = ScoutSessionDelegate()
        let url = try #require(URL(string: "http://scout.local/api/games"))
        let target = try #require(URL(string: "https://elsewhere.example.test/api/games"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]))
        let task = ScoutHTTP.shared.dataTask(with: url)
        defer { task.cancel() }
        let followed = await withCheckedContinuation { continuation in
            delegate.urlSession(ScoutHTTP.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
    }

    @Test func signOutRemovesTheServersCookies() throws {
        let host = StubServer.uniqueLocalHost()
        let address = try ServerAddress(userInput: "http://\(host):8000")
        let storage = HTTPCookieStorage.shared
        let cookie = try #require(HTTPCookie(properties: [
            .name: "scout_device", .value: "test-device-id.0000", .domain: host, .path: "/",
        ]))
        storage.setCookie(cookie)
        #expect(storage.cookies(for: address.origin)?.contains { $0.name == "scout_device" } == true)
        #expect(ScoutHTTP.removeCookies(for: address) == 1)
        #expect(storage.cookies(for: address.origin)?.isEmpty ?? true)
        #expect(ScoutHTTP.removeCookies(for: address) == 0)
    }
}

/// A challenge sender that is never used (the delegates only return a disposition).
nonisolated final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
