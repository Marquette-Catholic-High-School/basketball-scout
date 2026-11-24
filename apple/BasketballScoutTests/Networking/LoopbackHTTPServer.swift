import Foundation
import Network
import Synchronization

/// A tiny HTTP/1.1 server on 127.0.0.1 (a free port) for tests that need the real URL loading system: what
/// CFNetwork does after an authentication challenge (it may send a request again on a new connection) can
/// only be seen on a socket, never through a URLProtocol stub. Each request gets `respond`'s answer; every
/// connection closes after its answer, so each request the client sends is counted once.
nonisolated final class LoopbackHTTPServer: Sendable {
    nonisolated struct Request: Sendable {
        let method: String
        let path: String
        /// Header names lower-cased.
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    nonisolated struct Response: Sendable {
        var status: Int
        var reason: String
        var headers: [String: String]
        var body: Data

        static func json(_ status: Int, _ text: String, reason: String = "OK", headers: [String: String] = [:]) -> Response {
            Response(
                status: status, reason: reason, headers: ["Content-Type": "application/json"].merging(headers) { $1 },
                body: Data(text.utf8))
        }

        /// The server's 401 for missing or wrong credentials: its body and Basic challenge (scout/auth.py).
        static let challenge = Response.json(
            401,
            #"{"error":{"code":"AUTH_REQUIRED","title":"Sign-in required","message":"Enter the Basketball Scout username and password.","hint":"Ask the server administrator if you do not have them.","retryable":false,"detail":null}}"#,
            reason: "Unauthorized",
            headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#, "Cache-Control": "no-store"])
    }

    /// The port the server listens on.
    let port: UInt16
    private let listener: NWListener
    private let log: RequestLog

    private init(listener: NWListener, port: UInt16, log: RequestLog) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    /// Every request so far, in arrival order.
    var requests: [Request] { log.all }

    /// `http://127.0.0.1:<port>` (loopback: plain http needs no consent).
    var addressText: String { "http://127.0.0.1:\(port)" }

    func stop() {
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    /// This process may listen on a loopback port. The sandboxed Mac app (outgoing connections only) may not;
    /// the iOS Simulator may.
    static let canListen: Bool = {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0 && listen(descriptor, 1) == 0
    }()

    /// Starts listening; returns once the port is known.
    static func start(respond: @escaping @Sendable (Request) -> Response) async throws -> LoopbackHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LoopbackHTTPServer")
        let log = RequestLog()
        listener.newConnectionHandler = { connection in
            Exchange(connection: connection, queue: queue, log: log, respond: respond).start()
        }
        let resumed = ResumeOnce()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let outcome: Result<UInt16, any Error>?
                switch state {
                case .ready: outcome = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): outcome = .failure(error)
                case .cancelled: outcome = .failure(CancellationError())
                default: outcome = nil
                }
                guard let outcome, resumed.claim() else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
        return LoopbackHTTPServer(listener: listener, port: port, log: log)
    }

    /// True for the first caller only.
    private nonisolated final class ResumeOnce: Sendable {
        private let done = Mutex(false)

        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }

    /// The requests the server received.
    private nonisolated final class RequestLog: Sendable {
        private let items = Mutex<[Request]>([])

        var all: [Request] { items.withLock { $0 } }

        func record(_ request: Request) {
            items.withLock { $0.append(request) }
        }
    }

    /// One connection: reads one request (head and `Content-Length` body), answers, closes.
    private nonisolated final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let log: RequestLog
        private let respond: @Sendable (Request) -> Response
        /// Only touched on `queue` (every callback of the connection runs there).
        private var buffer = Data()

        init(connection: NWConnection, queue: DispatchQueue, log: RequestLog, respond: @escaping @Sendable (Request) -> Response) {
            self.connection = connection
            self.queue = queue
            self.log = log
            self.respond = respond
        }

        func start() {
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let request = parse() {
                    answer(request)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }

        /// The request once its head and body have arrived.
        private func parse() -> Request? {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let bodyStart = end.upperBound
            guard buffer.endIndex - bodyStart >= length else { return nil }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
        }

        private func answer(_ request: Request) {
            log.record(request)
            let response = respond(request)
            var headers = response.headers
            headers["Content-Length"] = String(response.body.count)
            headers["Connection"] = "close"
            var text = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
            text += "\r\n"
            var bytes = Data(text.utf8)
            bytes.append(response.body)
            connection.send(content: bytes, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
