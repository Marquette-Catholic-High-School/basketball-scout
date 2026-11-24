import Foundation

/// Chunked, resumable film upload and film by link (04 §2, §3; 09 D1 #8, R15–R20).
nonisolated extension APIClient {
    /// `POST /api/games/{game_id}/uploads` → 201, a new `open` session. Read `chunk_size` from it.
    func createUpload(gameID: String, _ body: UploadInit) async throws(APIError) -> UploadSession {
        try await decoded(
            APIRequest(.post, "/api/games/{game_id}/uploads", ["game_id": gameID], body: APIRequest.json(body)),
            as: UploadSession.self)
    }

    /// `GET /api/uploads/{upload_id}`: the session in any status. `received` is the only valid next offset;
    /// resync with this after any transport error (04 §2.8).
    func upload(id: String) async throws(APIError) -> UploadSession {
        try await decoded(APIRequest(.get, "/api/uploads/{upload_id}", ["upload_id": id]), as: UploadSession.self)
    }

    /// `PUT /api/uploads/{upload_id}/chunk?offset=N`: the raw bytes `[offset, offset + data.count)` as
    /// `application/octet-stream` (never multipart or JSON; 04 §2.4). One PUT at a time, `chunk_size` bytes
    /// (at most twice that), 60 s idle timeout. A 409 carrying `APIError.upload` is a resume point, not a
    /// failure.
    /// - Parameter progress: bytes of this chunk sent so far, for speed and the stall watchdog.
    func uploadChunk(
        uploadID: String, offset: Int, data: Data, progress: UploadProgressHandler? = nil
    ) async throws(APIError) -> UploadSession {
        let request = APIRequest(
            .put, "/api/uploads/{upload_id}/chunk", ["upload_id": uploadID],
            query: [.init("offset", String(offset))], body: .octetStream(data), timeout: Timeout.chunk)
        let exchange = try await perform(request, progress: progress)
        do {
            return try ScoutJSON.decoder().decode(UploadSession.self, from: exchange.data)
        } catch {
            throw APIError.from(decodingError: error, status: exchange.status)
        }
    }

    /// `POST /api/uploads/{upload_id}/complete?auto_start=…` (no body) → the game with its new film and,
    /// with `autoStart`, the queued ANALYZE job. A commit point: repeating it returns the same result
    /// (04 §2.5). Up to ~60 s on the server, so a 120 s timeout.
    func completeUpload(id: String, autoStart: Bool = true) async throws(APIError) -> FilmResult {
        try await decoded(
            APIRequest(
                .post, "/api/uploads/{upload_id}/complete", ["upload_id": id],
                query: [.init("auto_start", autoStart ? "true" : "false")], timeout: Timeout.heavy),
            as: FilmResult.self)
    }

    /// `DELETE /api/uploads/{upload_id}` → 204: abandons a session and its partial file. Cannot undo a
    /// `complete` that is running. A second call is a 404 `UPLOAD_NOT_FOUND`.
    func deleteUpload(id: String) async throws(APIError) {
        try await sendWithoutResult(APIRequest(.delete, "/api/uploads/{upload_id}", ["upload_id": id]))
    }

    /// `POST /api/games/{game_id}/video-url?auto_start=…` → 200 `FilmResult`: film by link. The server does
    /// not fetch the link now; download problems show up later as the job's error (04 §3). After a 503
    /// `QUEUE_UNAVAILABLE` the film has already changed: re-read the game (09 R19).
    func setVideoURL(gameID: String, _ body: VideoURLRequest, autoStart: Bool = true) async throws(APIError) -> FilmResult {
        try await decoded(
            APIRequest(
                .post, "/api/games/{game_id}/video-url", ["game_id": gameID],
                query: [.init("auto_start", autoStart ? "true" : "false")], body: APIRequest.json(body)),
            as: FilmResult.self)
    }
}
