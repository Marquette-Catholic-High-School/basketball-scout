import Foundation
import Synchronization
@testable import BasketballScout

/// Serves one film like Starlette's `FileResponse` (04 §4): 200 without `Range`, 206 with
/// `Content-Range` for `bytes=a-b`, `bytes=a-` and `bytes=-n`, 416 past the end, 405 for anything but
/// GET; the body in 4 KiB pieces. Records every request.
nonisolated final class FakeVideoServer: ServiceStubHandler {
    private struct State {
        var requests: [RecordedRequest] = []
        var override: ServiceStubReply?
        var holdData = false
        var held: [HeldReply] = []
    }

    let host: String
    let film: Data
    private let state = Mutex(State())

    init(film: Data) {
        self.host = ServiceStubRegistry.uniqueHost()
        self.film = film
        ServiceStubRegistry.register(self, host: host)
    }

    func client(credentials: ServerCredentials = ServiceStubSession.credentials) throws -> APIClient {
        try ServiceStubSession.client(host: host, credentials: credentials)
    }

    var requests: [RecordedRequest] { state.withLock { $0.requests } }
    var heldReplies: [HeldReply] { state.withLock { $0.held } }

    /// Answers every request with `reply` from now on (nil: serve the film again).
    func answerEverything(with reply: ServiceStubReply?) {
        state.withLock { $0.override = reply }
    }

    /// Holds every request from now on (until released or cancelled).
    func holdEverything() {
        state.withLock { $0.holdData = true }
    }

    func reply(to request: RecordedRequest) -> ServiceStubReply {
        let (override, hold) = state.withLock { state -> (ServiceStubReply?, Bool) in
            state.requests.append(request)
            return (state.override, state.holdData)
        }
        if let override { return override }
        if hold {
            let held = HeldReply { [self] in serve(request) }
            state.withLock { $0.held.append(held) }
            return .held(held)
        }
        return serve(request)
    }

    private func serve(_ request: RecordedRequest) -> ServiceStubReply {
        guard request.method == "GET" else {
            return .http(status: 405, headers: ["Allow": "GET"], pieces: [])
        }
        let total = film.count
        let common = ["Content-Type": "video/mp4", "Accept-Ranges": "bytes", "ETag": "\"0123456789abcdef0123456789abcdef\""]
        guard let rangeHeader = request.header("Range") else {
            return .http(status: 200, headers: common.merging(["Content-Length": "\(total)"]) { $1 }, pieces: pieces(of: film))
        }
        guard let (start, end) = Self.parse(rangeHeader, total: total) else {
            return .http(status: 400, headers: ["Content-Type": "text/plain"], pieces: [Data("Range header: range must be requested".utf8)])
        }
        guard start < total else {
            return .http(status: 416, headers: ["Content-Type": "text/plain", "Content-Range": "bytes */\(total)"], pieces: [])
        }
        let last = min(end, total - 1)
        let body = film.subdata(in: start..<(last + 1))
        let headers = common.merging(["Content-Range": "bytes \(start)-\(last)/\(total)", "Content-Length": "\(body.count)"]) { $1 }
        return .http(status: 206, headers: headers, pieces: pieces(of: body))
    }

    private func pieces(of data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: 4096).map { data.subdata(in: $0..<min($0 + 4096, data.count)) }
    }

    /// `bytes=a-b`, `bytes=a-`, `bytes=-n` → (start, inclusive end).
    static func parse(_ header: String, total: Int) -> (Int, Int)? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return (max(0, total - suffix), total - 1)
        }
        guard let start = Int(parts[0]) else { return nil }
        if parts[1].isEmpty { return (start, total - 1) }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return (start, end)
    }
}
