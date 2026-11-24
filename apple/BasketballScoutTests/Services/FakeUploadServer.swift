import Foundation
import Synchronization
@testable import BasketballScout

/// An in-memory Basketball Scout upload server (04 §2): sessions, strictly ordered chunks with the 409
/// resume point, `complete` (idempotent), DELETE, and film by link, plus injected faults (dropped
/// connections before or after storing a chunk, 5xx, 401, held requests, sessions another film aborted).
nonisolated final class FakeUploadServer: ServiceStubHandler {
    /// What the server saw, in order.
    nonisolated enum Step: Sendable, Equatable, CustomStringConvertible {
        case create
        case get(String)
        case chunk(offset: Int, length: Int)
        case complete(String)
        case delete(String)
        case videoLink
        case other(String)

        var description: String {
            switch self {
            case .create: "create"
            case .get(let id): "get \(id)"
            case .chunk(let offset, let length): "chunk \(offset)+\(length)"
            case .complete(let id): "complete \(id)"
            case .delete(let id): "delete \(id)"
            case .videoLink: "video-url"
            case .other(let text): text
            }
        }
    }

    /// Which request a fault applies to (each fault is used once).
    nonisolated enum Target: Sendable, Equatable {
        case create
        case get
        /// The n-th chunk PUT (0-based, counting every PUT).
        case chunk(Int)
        case complete
        case delete
        case videoLink
    }

    nonisolated enum Fault: Sendable {
        /// Store the chunk, then drop the connection (the client never sees the answer).
        case dropAfterStoring
        /// Drop the connection without storing anything.
        case dropBeforeStoring
        /// 502 from nginx.
        case badGateway
        /// 401 `AUTH_REQUIRED` (the password changed).
        case unauthorized
        /// The server already had `bytes` more (from `reference`): 409 `CONFLICT` with `upload`.
        case conflictAhead(bytes: Int)
        /// Hold the request until the test releases it (then it is handled normally).
        case hold
        /// `complete`: the film is saved, but the job queue is down (503 `QUEUE_UNAVAILABLE`).
        case queueUnavailable
        /// `complete`: the film is refused (422 `VIDEO_INVALID`; the session is aborted).
        case refuseFilm
        /// 404 `UPLOAD_NOT_FOUND` (the session expired or was deleted).
        case notFound
        /// A chunk: answer 200 as if stored, without storing (the next `complete` finds bytes missing).
        case pretendStored
        /// Answer with this instead.
        case reply(ServiceStubReply)
    }

    struct Session: Sendable {
        var id: String
        var gameID: String
        var filename: String
        var size: Int
        var chunkSize: Int
        var status: UploadStatus
        var data = Data()

        var received: Int { data.count }

        var model: UploadSession {
            UploadSession(
                id: id, gameID: gameID, filename: filename, size: size, received: received, chunkSize: chunkSize,
                status: status, createdAt: Date(timeIntervalSince1970: 1_794_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_794_000_000))
        }
    }

    private struct State {
        var sessions: [String: Session] = [:]
        var steps: [Step] = []
        var chunkCount = 0
        var nextID = 1
        var faults: [(target: Target, fault: Fault)] = []
        var held: [HeldReply] = []
        var authorizations: [String?] = []
        var chunkContentTypes: [String?] = []
        var completeQueries: [String?] = []
        var createBodies: [Data] = []
        var linkBodies: [Data] = []
        var linkQueries: [String?] = []
        var methods: [String] = []
    }

    let host: String
    let chunkSize: Int
    /// The film's true bytes (for `conflictAhead`).
    let reference: Data?
    private let state = Mutex(State())

    init(chunkSize: Int = 1000, reference: Data? = nil) {
        self.host = ServiceStubRegistry.uniqueHost()
        self.chunkSize = chunkSize
        self.reference = reference
        ServiceStubRegistry.register(self, host: host)
    }

    func client(credentials: ServerCredentials = ServiceStubSession.credentials) throws -> APIClient {
        try ServiceStubSession.client(host: host, credentials: credentials)
    }

    // MARK: - Test controls

    func add(_ fault: Fault, on target: Target) {
        state.withLock { $0.faults.append((target, fault)) }
    }

    /// Another film won (04 §2.7): the session is aborted.
    func abort(_ id: String) {
        state.withLock { $0.sessions[id]?.status = .aborted }
    }

    /// Makes a session as if an earlier run had sent `bytes` of `reference`.
    func makeSession(gameID: String, filename: String, size: Int, bytes: Int) -> String {
        state.withLock { state in
            let id = Self.makeID(&state)
            var session = Session(id: id, gameID: gameID, filename: filename, size: size, chunkSize: chunkSize, status: .open)
            session.data = reference.map { Data($0.prefix(bytes)) } ?? Data(count: bytes)
            state.sessions[id] = session
            return id
        }
    }

    // MARK: - Inspection

    var steps: [Step] { state.withLock { $0.steps } }
    var sessions: [Session] { state.withLock { Array($0.sessions.values) } }
    var heldReplies: [HeldReply] { state.withLock { $0.held } }
    var methods: [String] { state.withLock { $0.methods } }
    var chunkContentTypes: [String?] { state.withLock { $0.chunkContentTypes } }
    var completeQueries: [String?] { state.withLock { $0.completeQueries } }
    var createBodies: [Data] { state.withLock { $0.createBodies } }
    var linkBodies: [Data] { state.withLock { $0.linkBodies } }
    var linkQueries: [String?] { state.withLock { $0.linkQueries } }

    func session(_ id: String) -> Session? { state.withLock { $0.sessions[id] } }

    /// Every request carried the client's `Authorization` header.
    var everyRequestWasSignedIn: Bool {
        state.withLock { state in
            !state.authorizations.isEmpty && state.authorizations.allSatisfy { $0?.hasPrefix("Basic ") == true }
        }
    }

    /// The (offset, length) of every chunk PUT, in order.
    var chunks: [(offset: Int, length: Int)] {
        steps.compactMap { step in
            if case .chunk(let offset, let length) = step { return (offset, length) }
            return nil
        }
    }

    var deletedIDs: [String] {
        steps.compactMap { step in
            if case .delete(let id) = step { return id }
            return nil
        }
    }

    var createCount: Int { steps.filter { $0 == .create }.count }

    // MARK: - ServiceStubHandler

    func reply(to request: RecordedRequest) -> ServiceStubReply {
        let parts = request.path.split(separator: "/").map(String.init)
        state.withLock { state in
            state.authorizations.append(request.header("Authorization"))
            state.methods.append(request.method)
        }
        switch (request.method, parts.count) {
        case ("POST", 4) where parts[0] == "api" && parts[1] == "games" && parts[3] == "uploads":
            return create(gameID: parts[2], request: request)
        case ("GET", 3) where parts[0] == "api" && parts[1] == "uploads":
            return handle(.get, step: .get(parts[2])) { self.get(parts[2]) }
        case ("PUT", 4) where parts[1] == "uploads" && parts[3] == "chunk":
            return chunk(parts[2], request: request)
        case ("POST", 4) where parts[1] == "uploads" && parts[3] == "complete":
            state.withLock { $0.completeQueries.append(request.query) }
            return complete(parts[2])
        case ("DELETE", 3) where parts[1] == "uploads":
            return handle(.delete, step: .delete(parts[2])) { self.delete(parts[2]) }
        case ("POST", 4) where parts[1] == "games" && parts[3] == "video-url":
            state.withLock { state in
                state.linkBodies.append(request.body)
                state.linkQueries.append(request.query)
            }
            return handle(.videoLink, step: .videoLink) { .fixture("video_url_set.json") }
        default:
            state.withLock { $0.steps.append(.other("\(request.method) \(request.path)")) }
            return .json(404, Self.errorBody(code: "NOT_FOUND", title: "Not found", message: "No such route."))
        }
    }

    // MARK: - Routes

    private func create(gameID: String, request: RecordedRequest) -> ServiceStubReply {
        state.withLock { $0.createBodies.append(request.body) }
        return handle(.create, step: .create) {
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let filename = body["filename"] as? String, let size = body["size"] as? Int
            else {
                return .json(422, Self.errorBody(code: "VALIDATION_FAILED", title: "Invalid request", message: "Some fields are invalid."))
            }
            let session = self.state.withLock { state in
                let id = Self.makeID(&state)
                let session = Session(id: id, gameID: gameID, filename: filename, size: size, chunkSize: self.chunkSize, status: .open)
                state.sessions[id] = session
                return session
            }
            return .json(201, Self.encode(session.model))
        }
    }

    private func get(_ id: String) -> ServiceStubReply {
        guard let session = state.withLock({ $0.sessions[id] }) else { return Self.notFoundReply }
        return .json(200, Self.encode(session.model))
    }

    private func delete(_ id: String) -> ServiceStubReply {
        let removed = state.withLock { $0.sessions.removeValue(forKey: id) }
        return removed == nil ? Self.notFoundReply : .empty(204)
    }

    private func chunk(_ id: String, request: RecordedRequest) -> ServiceStubReply {
        let offset = request.query.flatMap { query -> Int? in
            query.split(separator: "&").first { $0.hasPrefix("offset=") }.flatMap { Int($0.dropFirst(7)) }
        }
        let fault = state.withLock { state -> Fault? in
            let index = state.chunkCount
            state.chunkCount += 1
            state.chunkContentTypes.append(request.header("Content-Type"))
            state.steps.append(.chunk(offset: offset ?? -1, length: request.body.count))
            return Self.takeFault(.chunk(index), from: &state)
        }
        guard let offset else {
            return .json(422, Self.errorBody(code: "VALIDATION_FAILED", title: "Invalid request", message: "Some fields are invalid."))
        }
        switch fault {
        case .dropBeforeStoring?:
            return .failure(URLError(.networkConnectionLost))
        case .dropAfterStoring?:
            _ = store(request.body, at: offset, in: id)
            return .failure(URLError(.networkConnectionLost))
        case .pretendStored?:
            return state.withLock { state -> ServiceStubReply in
                guard let session = state.sessions[id] else { return Self.notFoundReply }
                var model = session.model
                model.received = offset + request.body.count
                return .json(200, Self.encode(model))
            }
        case .conflictAhead(let bytes)?:
            return state.withLock { state -> ServiceStubReply in
                guard var session = state.sessions[id], let reference else { return Self.notFoundReply }
                let end = min(session.size, session.received + bytes)
                session.data.append(reference[session.received..<end])
                state.sessions[id] = session
                return .json(409, Self.errorBody(
                    code: "CONFLICT", title: "Conflict",
                    message: "The server has \(session.received) bytes of this upload, but the chunk starts at byte \(offset).",
                    hint: "Resume from upload.received.", upload: session.model))
            }
        case .hold?:
            let body = request.body
            let held = HeldReply { [self] in store(body, at: offset, in: id) }
            state.withLock { $0.held.append(held) }
            return .held(held)
        case let fault?:
            return reply(for: fault, sessionID: id)
        case nil:
            return store(request.body, at: offset, in: id)
        }
    }

    /// The real chunk rules (04 §2.4).
    private func store(_ body: Data, at offset: Int, in id: String) -> ServiceStubReply {
        state.withLock { state -> ServiceStubReply in
            guard var session = state.sessions[id] else { return Self.notFoundReply }
            guard session.status == .open else {
                return .json(409, Self.errorBody(
                    code: "CONFLICT", title: "Conflict", message: "This upload is already \(session.status.rawValue).",
                    hint: "Start a new upload."))
            }
            guard offset == session.received else {
                return .json(409, Self.errorBody(
                    code: "CONFLICT", title: "Conflict",
                    message: "The server has \(session.received) bytes of this upload, but the chunk starts at byte \(offset).",
                    hint: "Resume from upload.received.", upload: session.model))
            }
            guard body.count <= 2 * session.chunkSize, offset + body.count <= session.size else {
                return .json(413, Self.errorBody(code: "UPLOAD_TOO_LARGE", title: "Upload too large", message: "Chunks may be at most \(2 * session.chunkSize) bytes."))
            }
            session.data.append(body)
            state.sessions[id] = session
            return .json(200, Self.encode(session.model))
        }
    }

    private func complete(_ id: String) -> ServiceStubReply {
        let fault = state.withLock { state -> Fault? in
            state.steps.append(.complete(id))
            return Self.takeFault(.complete, from: &state)
        }
        switch fault {
        case .hold?:
            let held = HeldReply { [self] in finishSession(id) }
            state.withLock { $0.held.append(held) }
            return .held(held)
        case .queueUnavailable?:
            _ = finishSession(id)
            return .json(503, Self.queueUnavailableBody)
        case .dropAfterStoring?:
            _ = finishSession(id)
            return .failure(URLError(.networkConnectionLost))
        case .refuseFilm?:
            state.withLock { $0.sessions[id]?.status = .aborted }
            return .json(422, Self.errorBody(
                code: "VIDEO_INVALID", title: "Not a usable video",
                message: "'Test Film.mp4' is not an MP4/MOV video (its header is wrong).",
                hint: "Export the film as H.264 MP4 (Hudl: Download > MP4) and upload again."))
        case let fault?:
            return reply(for: fault, sessionID: id)
        case nil:
            return finishSession(id)
        }
    }

    /// The real `complete` rules (04 §2.5): idempotent once complete.
    private func finishSession(_ id: String) -> ServiceStubReply {
        state.withLock { state -> ServiceStubReply in
            guard var session = state.sessions[id] else { return Self.notFoundReply }
            switch session.status {
            case .complete:
                return .fixture("upload_complete.json")
            case .open:
                guard session.received == session.size else {
                    return .json(409, Self.errorBody(
                        code: "UPLOAD_INCOMPLETE", title: "Upload incomplete",
                        message: "Only \(session.received) of \(session.size) bytes have arrived.",
                        hint: "Retry the upload; it resumes where it stopped.", retryable: true))
                }
                session.status = .complete
                state.sessions[id] = session
                for (otherID, other) in state.sessions where other.gameID == session.gameID && other.status == .open {
                    state.sessions[otherID]?.status = .aborted
                }
                return .fixture("upload_complete.json")
            default:
                return .json(409, Self.errorBody(code: "CONFLICT", title: "Conflict", message: "This upload is already aborted.", hint: "Start a new upload."))
            }
        }
    }

    /// Applies a fault (if any) for `target`, else `normal`.
    private func handle(_ target: Target, step: Step, normal: @escaping @Sendable () -> ServiceStubReply) -> ServiceStubReply {
        let fault = state.withLock { state -> Fault? in
            state.steps.append(step)
            return Self.takeFault(target, from: &state)
        }
        guard let fault else { return normal() }
        if case .hold = fault {
            let held = HeldReply(produce: normal)
            state.withLock { $0.held.append(held) }
            return .held(held)
        }
        return reply(for: fault, sessionID: nil)
    }

    private func reply(for fault: Fault, sessionID: String?) -> ServiceStubReply {
        switch fault {
        case .dropAfterStoring, .dropBeforeStoring:
            return .failure(URLError(.networkConnectionLost))
        case .badGateway:
            return .html(502)
        case .unauthorized:
            return .json(401, Self.errorBody(
                code: "AUTH_REQUIRED", title: "Sign-in required", message: "Enter the coaches' username and password."),
                headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout", charset="UTF-8""#])
        case .notFound:
            return Self.notFoundReply
        case .queueUnavailable:
            return .json(503, Self.queueUnavailableBody)
        case .reply(let reply):
            return reply
        case .hold, .conflictAhead, .refuseFilm, .pretendStored:
            return .html(500)
        }
    }

    // MARK: - Bodies

    private static func takeFault(_ target: Target, from state: inout State) -> Fault? {
        guard let index = state.faults.firstIndex(where: { $0.target == target }) else { return nil }
        return state.faults.remove(at: index).fault
    }

    private static func makeID(_ state: inout State) -> String {
        defer { state.nextID += 1 }
        return "u_" + String(format: "%012x", 0xabc000 + state.nextID)
    }

    static func encode(_ session: UploadSession) -> Data {
        (try? ScoutJSON.encode(session)) ?? Data()
    }

    static func errorBody(
        code: String, title: String, message: String, hint: String? = nil, retryable: Bool = false, upload: UploadSession? = nil
    ) -> Data {
        let envelope = ErrorEnvelope(
            error: ErrorInfo(code: code, title: title, message: message, hint: hint, retryable: retryable), upload: upload)
        return (try? ScoutJSON.encode(envelope)) ?? Data()
    }

    static let notFoundReply = ServiceStubReply.json(404, errorBody(
        code: "UPLOAD_NOT_FOUND", title: "Upload not found", message: "That upload session does not exist or has expired.",
        hint: "Start the upload again."))

    /// 09 §C4.
    static let queueUnavailableBody = errorBody(
        code: "QUEUE_UNAVAILABLE", title: "Job queue unavailable", message: "The job queue (Redis) could not be reached.",
        hint: "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.", retryable: true)
}
