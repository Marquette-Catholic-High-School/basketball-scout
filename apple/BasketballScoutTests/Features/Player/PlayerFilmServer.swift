import Foundation
import Synchronization
@testable import BasketballScout

/// A stub server for the player's tests: serves one film for both copies (`variant=original` /
/// `variant=annotated`) with byte ranges like Starlette's `FileResponse` (04 §4), and lets a test answer
/// one copy (or both) with something else: a JSON error, a dropped connection, bytes that are not a film.
/// Records every request.
nonisolated final class PlayerFilmServer: ServiceStubHandler {
    private struct State {
        var requests: [RecordedRequest] = []
        var overrides: [String: ServiceStubReply] = [:]
        var films: [String: Data] = [:]
    }

    let host: String
    private let film: Data
    private let state = Mutex(State())

    init(film: Data) {
        host = ServiceStubRegistry.uniqueHost()
        self.film = film
        ServiceStubRegistry.register(self, host: host)
    }

    func client() throws -> APIClient {
        try ServiceStubSession.client(host: host)
    }

    var requests: [RecordedRequest] { state.withLock { $0.requests } }

    /// Requests for `variant` ("original" / "annotated").
    func requests(for variant: String) -> [RecordedRequest] {
        requests.filter { Self.variant(of: $0) == variant }
    }

    /// Answers every request for `variant` with `reply` (nil: serve the film again).
    func answer(_ variant: String, with reply: ServiceStubReply?) {
        state.withLock { $0.overrides[variant] = reply }
    }

    /// Serves `bytes` (with ranges) for `variant` instead of the film.
    func serve(_ bytes: Data, for variant: String) {
        state.withLock { $0.films[variant] = bytes }
    }

    func reply(to request: RecordedRequest) -> ServiceStubReply {
        let variant = Self.variant(of: request)
        let (override, bytes) = state.withLock { state -> (ServiceStubReply?, Data?) in
            state.requests.append(request)
            return (state.overrides[variant], state.films[variant])
        }
        if let override { return override }
        return Self.serve(bytes ?? film, request: request)
    }

    private static func variant(of request: RecordedRequest) -> String {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "variant" }?.value ?? "original"
    }

    private static func serve(_ data: Data, request: RecordedRequest) -> ServiceStubReply {
        guard request.method == "GET" else {
            return .http(status: 405, headers: ["Allow": "GET"], pieces: [])
        }
        let total = data.count
        let common = ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"]
        guard let range = request.header("Range") else {
            return .http(status: 200, headers: common.merging(["Content-Length": "\(total)"]) { $1 }, pieces: [data])
        }
        guard let (start, end) = FakeVideoServer.parse(range, total: total) else {
            return .http(status: 400, headers: ["Content-Type": "text/plain"], pieces: [Data("Range header: range must be requested".utf8)])
        }
        guard start < total else {
            return .http(status: 416, headers: ["Content-Type": "text/plain", "Content-Range": "bytes */\(total)"], pieces: [])
        }
        let last = min(end, total - 1)
        let body = data.subdata(in: start..<(last + 1))
        let headers = common.merging(["Content-Range": "bytes \(start)-\(last)/\(total)", "Content-Length": "\(body.count)"]) { $1 }
        let pieces = stride(from: 0, to: body.count, by: 16_384).map { body.subdata(in: $0..<min($0 + 16_384, body.count)) }
        return .http(status: 206, headers: headers, pieces: pieces)
    }
}
