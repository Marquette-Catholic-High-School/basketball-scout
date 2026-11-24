import Foundation
import Synchronization
@testable import BasketballScout

/// A request as the stubbed server received it.
nonisolated struct RecordedRequest: Sendable, CustomStringConvertible {
    let method: String
    let url: URL
    /// Header fields as set on the request (names as written).
    let headers: [String: String]
    let body: Data

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url ?? URL(fileURLWithPath: "/")
        headers = request.allHTTPHeaderFields ?? [:]
        body = Self.body(of: request)
    }

    /// A header by name, case-insensitively.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The percent-encoded path.
    var path: String { url.path(percentEncoded: true) }
    /// The percent-encoded query, or nil.
    var query: String? { url.query(percentEncoded: true) }
    var bodyText: String { String(decoding: body, as: UTF8.self) }

    var description: String { "\(method) \(path)\(query.map { "?" + $0 } ?? "")" }

    /// The body, from `httpBody` or (for upload tasks and bodies URLSession turned into a stream)
    /// `httpBodyStream`.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// What the stubbed server answers.
nonisolated enum StubResponse: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    case failure(URLError)
    /// An HTTP authentication challenge, as CFNetwork raises one for a 401 with `WWW-Authenticate`: the
    /// delegate gets the challenge with this answer as its `failureResponse` (the body never reaches the app).
    /// Cancelling it fails the task with `URLError.cancelled`, as on a real connection.
    case challenge(status: Int, headers: [String: String])

    /// The server's 401 for missing or wrong credentials, with its Basic challenge (02 §3.3).
    static let basicChallenge = StubResponse.challenge(
        status: 401, headers: [
            "Content-Type": "application/json", "Cache-Control": "no-store",
            "WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#,
        ])

    /// JSON with `Content-Type: application/json`.
    static func json(_ status: Int = 200, _ text: String, headers: [String: String] = [:]) -> StubResponse {
        .http(status: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: Data(text.utf8))
    }

    /// A captured fixture body with the given status and headers (JSON by default).
    static func fixture(
        _ name: String, status: Int = 200, contentType: String = "application/json", headers: [String: String] = [:]
    ) -> StubResponse {
        let body = (try? Fixture.data(name)) ?? Data()
        return .http(status: status, headers: ["Content-Type": contentType].merging(headers) { $1 }, body: body)
    }

    /// A body of another type (HTML from nginx, text exports).
    static func text(_ status: Int, _ text: String, contentType: String = "text/html", headers: [String: String] = [:]) -> StubResponse {
        .http(status: status, headers: ["Content-Type": contentType].merging(headers) { $1 }, body: Data(text.utf8))
    }

    /// No body (204, an empty 400 or 416).
    static func empty(_ status: Int = 204, headers: [String: String] = [:]) -> StubResponse {
        .http(status: status, headers: headers, body: Data())
    }
}

/// A fake Basketball Scout server for one test: answers every request to its unique host with
/// `handler` and records the requests. Hosts are unique, so tests can run in parallel.
nonisolated final class StubServer: Sendable {
    let host: String
    private let state: Mutex<[RecordedRequest]>
    private let handler: @Sendable (RecordedRequest) -> StubResponse

    /// - Parameters:
    ///   - host: a host nobody else uses (`StubServer.uniqueLocalHost()` etc.).
    ///   - handler: the answer for each request.
    init(host: String = StubServer.uniqueLocalHost(), handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        self.host = host
        self.handler = handler
        self.state = Mutex([])
        StubRegistry.register(self)
    }

    /// Answers every request with `response`.
    convenience init(host: String = StubServer.uniqueLocalHost(), always response: StubResponse) {
        self.init(host: host) { _ in response }
    }

    /// Every request so far, in order.
    var requests: [RecordedRequest] { state.withLock { $0 } }

    /// The only request; fails the test expectation in the caller when there were others.
    var lastRequest: RecordedRequest? { requests.last }

    func respond(to request: RecordedRequest) -> StubResponse {
        state.withLock { $0.append(request) }
        return handler(request)
    }

    // MARK: Unique hosts

    private static let counter = Atomic<Int>(0)

    private static func next() -> Int { counter.add(1, ordering: .relaxed).newValue }

    /// `stub-N.local` (plain http allowed).
    static func uniqueLocalHost() -> String { "stub-\(next()).local" }

    /// `10.77.x.y` (plain http allowed).
    static func uniqueIPv4() -> String {
        let n = next()
        return "10.77.\(n / 250 % 250).\(n % 250 + 1)"
    }

    /// `stub-N.example.test` (a dotted name: https only).
    static func uniqueDomain() -> String { "stub-\(next()).example.test" }
}

/// Routes requests to the stub server of their host.
nonisolated enum StubRegistry {
    private static let servers = Mutex<[String: StubServer]>([:])

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.host.lowercased()] = server }
    }

    static func server(for host: String?) -> StubServer? {
        guard var host = host?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return servers.withLock { $0[host] }
    }
}

/// The URL loading system's side of the stub. Installed only in `StubSession.shared`.
nonisolated final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(request)
        guard let server = StubRegistry.server(for: request.url?.host(percentEncoded: false)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: recorded.url]))
            return
        }
        switch server.respond(to: recorded) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .challenge(let status, let headers):
            guard let challenge = Self.challenge(for: request, status: status, headers: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            // URLSession answers it through the task's delegate; a cancel fails the task (-999).
            client?.urlProtocol(self, didReceive: challenge)
        case .http(let status, let headers, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// The HTTP Basic challenge for `request` with `status`/`headers` as its failure response. URLSession
    /// answers a protocol's challenge itself (a cancel stops the task), so the sender is never called.
    static func challenge(for request: URLRequest, status: Int, headers: [String: String]) -> URLAuthenticationChallenge? {
        guard let url = request.url, let host = url.host(percentEncoded: false),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return nil }
        let scheme = url.scheme ?? "http"
        let space = URLProtectionSpace(
            host: host, port: url.port ?? (scheme == "https" ? 443 : 80), protocol: scheme, realm: "Basketball Scout",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: response, error: nil,
            sender: ChallengeSender())
    }
}

/// The app's session configuration with the stub protocol: no request leaves the machine.
nonisolated enum StubSession {
    static let shared: URLSession = {
        let configuration = ScoutHTTP.makeConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return ScoutHTTP.makeSession(configuration: configuration)
    }()
}

/// Building blocks shared by the networking tests.
nonisolated enum TestServer {
    /// The test password: non-ASCII and with a colon, to check the exact Basic encoding (02 §3.1).
    static let credentials = ServerCredentials(username: "coach", password: "pässwörd:ü€ 1")
    /// `Basic base64(UTF-8 "coach:pässwörd:ü€ 1")`, computed independently (Python's base64).
    static let expectedAuthorization = "Basic Y29hY2g6cMOkc3N3w7ZyZDrDvOKCrCAx"

    /// A client for `server` over plain http on port 8000.
    static func client(for server: StubServer, credentials: ServerCredentials = TestServer.credentials) throws -> APIClient {
        let address = try ServerAddress(userInput: "http://\(server.host):8000")
        return APIClient(address: address, credentials: credentials, session: StubSession.shared)
    }
}
