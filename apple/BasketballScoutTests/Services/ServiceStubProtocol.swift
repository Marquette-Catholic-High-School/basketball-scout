import Foundation
import Synchronization
@testable import BasketballScout

/// What a stubbed service server answers.
nonisolated enum ServiceStubReply: Sendable {
    /// The headers at once, then the body in `pieces` (one `didLoad` each, so streaming is exercised).
    case http(status: Int, headers: [String: String], pieces: [Data])
    /// No HTTP answer (offline, a dropped connection).
    case failure(URLError)
    /// No answer until the test releases it; a client cancel is recorded.
    case held(HeldReply)
    /// The HTTP Basic challenge CFNetwork raises for a 401 with `WWW-Authenticate`, with this answer as its
    /// `failureResponse` (see `StubResponse.challenge`).
    case challenge(status: Int, headers: [String: String])

    /// The server's 401 with its Basic challenge (02 §3.3).
    static let basicChallenge = ServiceStubReply.challenge(
        status: 401, headers: [
            "Content-Type": "application/json", "Cache-Control": "no-store",
            "WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#,
        ])

    /// JSON with `Content-Type: application/json`.
    static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> ServiceStubReply {
        .http(status: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, pieces: [body])
    }

    /// A captured fixture body.
    static func fixture(_ name: String, status: Int = 200) -> ServiceStubReply {
        .json(status, (try? Fixture.data(name)) ?? Data())
    }

    /// No body (204).
    static func empty(_ status: Int) -> ServiceStubReply {
        .http(status: status, headers: [:], pieces: [])
    }

    /// An nginx-style HTML page.
    static func html(_ status: Int) -> ServiceStubReply {
        .http(status: status, headers: ["Content-Type": "text/html"], pieces: [Data("<html><body>\(status)</body></html>".utf8)])
    }
}

/// A request the stub holds back. The test releases it (the stub's `produce` makes the answer then);
/// a cancel by the client is recorded and nothing is delivered afterwards.
nonisolated final class HeldReply: Sendable {
    private struct State {
        var deliver: (@Sendable (ServiceStubReply) -> Void)?
        var isCancelled = false
        var isReleased = false
    }

    private let state = Mutex(State())
    private let produce: @Sendable () -> ServiceStubReply

    init(produce: @escaping @Sendable () -> ServiceStubReply) {
        self.produce = produce
    }

    /// The client cancelled the request (pause, cancel, invalidate).
    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    /// Arrived and still waiting.
    var isWaiting: Bool { state.withLock { $0.deliver != nil && !$0.isCancelled && !$0.isReleased } }

    /// Answers the request now (with `produce()`), unless it was cancelled.
    func release() {
        let deliver = state.withLock { state -> (@Sendable (ServiceStubReply) -> Void)? in
            guard !state.isCancelled, !state.isReleased else { return nil }
            state.isReleased = true
            return state.deliver
        }
        deliver?(produce())
    }

    func attach(_ deliver: @escaping @Sendable (ServiceStubReply) -> Void) {
        state.withLock { $0.deliver = deliver }
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }
}

/// A stubbed server for one host.
nonisolated protocol ServiceStubHandler: AnyObject, Sendable {
    func reply(to request: RecordedRequest) -> ServiceStubReply
}

/// Routes stub requests to the handler of their host. Hosts are unique, so tests run in parallel.
nonisolated enum ServiceStubRegistry {
    private static let handlers = Mutex<[String: any ServiceStubHandler]>([:])
    private static let counter = Atomic<Int>(0)

    /// `svc-N.local` (plain http allowed).
    static func uniqueHost() -> String {
        "svc-\(counter.add(1, ordering: .relaxed).newValue).local"
    }

    static func register(_ handler: any ServiceStubHandler, host: String) {
        handlers.withLock { $0[host.lowercased()] = handler }
    }

    static func handler(for host: String?) -> (any ServiceStubHandler)? {
        guard let host = host?.lowercased() else { return nil }
        return handlers.withLock { $0[host] }
    }
}

/// The URL loading system's side. Installed only in `ServiceStubSession.shared`.
nonisolated final class ServiceStubProtocol: URLProtocol {
    /// Lets a held reply reach this request later, on its own run loop.
    private nonisolated final class Pending: @unchecked Sendable {
        weak var request: ServiceStubProtocol?
        let runLoop: CFRunLoop

        init(request: ServiceStubProtocol, runLoop: CFRunLoop) {
            self.request = request
            self.runLoop = runLoop
        }

        func deliver(_ reply: ServiceStubReply) {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in request?.deliver(reply) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private let held = Mutex<HeldReply?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(request)
        guard let handler = ServiceStubRegistry.handler(for: request.url?.host(percentEncoded: false)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = handler.reply(to: recorded)
        guard case .held(let hold) = reply else {
            deliver(reply)
            return
        }
        held.withLock { $0 = hold }
        // Answer later on this request's own run loop, as URLProtocol expects.
        let pending = Pending(request: self, runLoop: CFRunLoopGetCurrent())
        hold.attach { reply in pending.deliver(reply) }
    }

    override func stopLoading() {
        held.withLock { $0 }?.cancel()
    }

    fileprivate func deliver(_ reply: ServiceStubReply) {
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .challenge(let status, let headers):
            guard let challenge = StubURLProtocol.challenge(for: request, status: status, headers: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: challenge)
        case .http(let status, let headers, let pieces):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for piece in pieces where !piece.isEmpty { client?.urlProtocol(self, didLoad: piece) }
            client?.urlProtocolDidFinishLoading(self)
        case .held:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
}

/// The app's session configuration with the service stub: nothing leaves the machine.
nonisolated enum ServiceStubSession {
    static let shared: URLSession = {
        let configuration = ScoutHTTP.makeConfiguration()
        configuration.protocolClasses = [ServiceStubProtocol.self]
        return ScoutHTTP.makeSession(configuration: configuration)
    }()

    /// The test password (not a real one; never printed).
    static let credentials = ServerCredentials(username: "coach", password: "services-test-pw-1")

    /// A client for `host` over plain http on port 8000.
    static func client(host: String, credentials: ServerCredentials = ServiceStubSession.credentials) throws -> APIClient {
        let address = try ServerAddress(userInput: "http://\(host):8000")
        return APIClient(address: address, credentials: credentials, session: shared)
    }
}
