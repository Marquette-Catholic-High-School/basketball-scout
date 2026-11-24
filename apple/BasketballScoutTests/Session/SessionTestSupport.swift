import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// A stubbed Basketball Scout server for the session tests, on the services stub (held replies possible).
///
/// Sign-in works out of the box (02 §11): `GET /api/health/live` → 200, `GET /api/health` without
/// credentials → 401 with the realm, with credentials → `health.json` (or `healthReply`). Other routes
/// answer from queues set with `on(_:_:_:)`: each request takes the next reply, the last one repeats.
/// Anything else is a 404.
nonisolated final class SessionStubServer: ServiceStubHandler {
    let host: String
    private let state = Mutex(State())

    private struct State {
        var routes: [String: [ServiceStubReply]] = [:]
        var requests: [RecordedRequest] = []
        var signedInHealth: ServiceStubReply = .fixture("health.json")
    }

    init() {
        host = ServiceStubRegistry.uniqueHost()
        ServiceStubRegistry.register(self, host: host)
    }

    /// The server's address (plain http to a `.local` name, port 8000).
    var address: ServerAddress {
        get throws { try ServerAddress(userInput: "http://\(host):8000") }
    }

    /// Answers `method path` with `replies`, one per request; the last one repeats.
    func on(_ method: String, _ path: String, _ replies: ServiceStubReply...) {
        state.withLock { $0.routes["\(method) \(path)"] = replies }
    }

    /// What a signed-in `GET /api/health` answers.
    func setHealth(_ reply: ServiceStubReply) {
        state.withLock { $0.signedInHealth = reply }
    }

    /// Every request so far.
    var requests: [RecordedRequest] { state.withLock { $0.requests } }

    /// How many requests went to `method path`.
    func count(_ method: String, _ path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    /// Requests that carried `Authorization`.
    var credentialedRequests: [RecordedRequest] {
        requests.filter { $0.header("Authorization") != nil }
    }

    func reply(to request: RecordedRequest) -> ServiceStubReply {
        state.withLock { state in
            state.requests.append(request)
            let key = "\(request.method) \(request.path)"
            if var queue = state.routes[key], let first = queue.first {
                if queue.count > 1 {
                    queue.removeFirst()
                    state.routes[key] = queue
                }
                return first
            }
            switch key {
            case "GET /api/health/live":
                return .fixture("health_live.json")
            case "GET /api/health":
                if request.header("Authorization") == nil {
                    return .json(401, (try? Fixture.data("err_401_no_auth.json")) ?? Data(),
                                 headers: ["WWW-Authenticate": "Basic realm=\"Basketball Scout\", charset=\"UTF-8\""])
                }
                return state.signedInHealth
            default:
                return .json(404, Data(#"{"error":{"code":"NOT_FOUND","title":"Not found","message":"There is nothing at \#(request.path).","hint":null,"retryable":false,"detail":null}}"#.utf8))
            }
        }
    }
}

/// A settable clock for the session (lockout countdown, worker checks).
nonisolated final class SessionClock: Sendable {
    private let value: Mutex<Date>
    /// Added to the time after every reading (0: the clock stands still).
    private let step: TimeInterval

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000), step: TimeInterval = 0) {
        value = Mutex(start)
        self.step = step
    }

    var now: Date {
        value.withLock { date in
            defer { date = date.addingTimeInterval(step) }
            return date
        }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var reader: @Sendable () -> Date { { self.now } }
}

/// A `ServerSession` with private settings, an in-memory Keychain, its own analysis cache and a stubbed
/// network; nothing touches the user's data.
@MainActor
final class SessionHarness {
    let server: SessionStubServer
    let defaults: UserDefaults
    let keychain = InMemoryKeychainStore()
    let profiles: ServerProfileStore
    let lockouts: LockoutStore
    let cacheFolder: URL
    let cache: AnalysisCache
    let clock: SessionClock
    let session: ServerSession
    /// What the session's hooks were called with.
    private(set) var stops: [ServerSessionStopReason] = []
    private(set) var reachableCount = 0
    private(set) var serverChangedCount = 0
    private(set) var signedOutCount = 0

    /// The test password (not a real one; never printed).
    static let password = "session-test-pw-1"

    init(server: SessionStubServer = SessionStubServer(), clock: SessionClock = SessionClock()) {
        self.server = server
        self.clock = clock
        let suite = "SessionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        profiles = ServerProfileStore(defaults: defaults, key: "profiles")
        lockouts = LockoutStore(defaults: defaults, key: "lockouts")
        cacheFolder = FileManager.default.temporaryDirectory.appending(path: "SessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = AnalysisCache(directory: cacheFolder)
        session = ServerSession(
            profiles: profiles, keychain: keychain, httpSession: ServiceStubSession.shared,
            lockouts: lockouts, analysisCache: cache, now: clock.reader)
        session.onStopAll = { [unowned self] reason in stops.append(reason) }
        session.onReachable = { [unowned self] in reachableCount += 1 }
        session.onServerChanged = { [unowned self] in serverChangedCount += 1 }
        session.onSignedOut = { [unowned self] in signedOutCount += 1 }
    }

    /// Signs in to the stub server (accepting plain http) and checks it worked.
    @discardableResult
    func signIn() async throws -> APIClient {
        let result = await session.signIn(
            address: try server.address, username: "coach", password: Self.password, acceptPlainHTTP: true)
        #expect(result.success != nil, "sign-in should succeed: \(String(describing: result.problem?.title))")
        return try #require(session.client)
    }

    /// The Keychain entry the session uses for the stub server.
    var account: KeychainAccount {
        get throws { KeychainAccount(address: try server.address, username: "coach") }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}

/// Builds JSON bodies from fixtures with changes (no names other than the fixtures' "Test Team …").
nonisolated enum SessionFixtures {
    static func game(_ name: String, change: (inout Game) -> Void = { _ in }) throws -> Game {
        var game = try Fixture.decode(Game.self, name)
        change(&game)
        return game
    }

    static func job(_ name: String, change: (inout Job) -> Void = { _ in }) throws -> Job {
        var job = try Fixture.decode(Job.self, name)
        change(&job)
        return job
    }

    static func reply<T: Encodable>(_ value: T, status: Int = 200) throws -> ServiceStubReply {
        .json(status, try ScoutJSON.encode(value))
    }

    /// The server's error body.
    static func error(_ status: Int, code: String, title: String, message: String, retryable: Bool = false, headers: [String: String] = [:]) -> ServiceStubReply {
        let body = #"{"error":{"code":"\#(code)","title":"\#(title)","message":"\#(message)","hint":null,"retryable":\#(retryable),"detail":null}}"#
        return .json(status, Data(body.utf8), headers: headers)
    }
}
