import Foundation

/// Live games (docs/LIVE.md "HTTP API"): start a live stream, read its status, open the upload of one part,
/// and say that no more film is coming. A part's bytes go through the film upload routes
/// (`uploadChunk(uploadID:offset:data:progress:)`, then `completeUpload(id:autoStart:)`).
nonisolated extension APIClient {
    /// `POST /api/games/{game_id}/live` → 201 `LiveStatus`: the game becomes a live game and its LIVE job is
    /// queued. Asked again while it is capturing: 200 with the running session (a capture client resumes with
    /// it). Without `segmentSeconds` no body is sent and the server picks the part length: read it from
    /// `game.live.segmentSeconds`. 409 `CONFLICT` when the game already has film or another analysis is
    /// running; 409 `LIVE_ENDED` when its live stream has ended.
    func startLive(gameID: String, segmentSeconds: Int? = nil) async throws(APIError) -> LiveStatus {
        var body = APIRequest.Body.none
        if let segmentSeconds { body = try APIRequest.json(LiveStart(segmentSeconds: segmentSeconds)) }
        return try await decoded(
            APIRequest(.post, "/api/games/{game_id}/live", ["game_id": gameID], body: body),
            as: LiveStatus.self)
    }

    /// `GET /api/games/{game_id}/live` → `LiveStatus`: the game, its parts and the LIVE job. 404 for a game
    /// that was never live.
    func liveStatus(gameID: String) async throws(APIError) -> LiveStatus {
        try await decoded(APIRequest(.get, "/api/games/{game_id}/live", ["game_id": gameID]), as: LiveStatus.self)
    }

    /// `POST /api/games/{game_id}/live/segments` → an upload session for one part (MP4 only): 201 for a new
    /// one; 200 with `status == .complete` when the part is already on the server (send nothing), or with
    /// `status == .open` when it was half-sent with the same size (resume from `received`). 409 `LIVE_ENDED`
    /// once the game no longer takes film.
    func createLiveSegmentUpload(gameID: String, _ body: LiveSegmentInit) async throws(APIError) -> UploadSession {
        try await decoded(
            APIRequest(.post, "/api/games/{game_id}/live/segments", ["game_id": gameID], body: APIRequest.json(body)),
            as: UploadSession.self)
    }

    /// `POST /api/games/{game_id}/live/finish` (no body) → `LiveStatus` with `state == .finishing`: no more
    /// film is coming; the parts already sent are analysed, then the game ends. Can be repeated.
    func finishLive(gameID: String) async throws(APIError) -> LiveStatus {
        try await decoded(
            APIRequest(.post, "/api/games/{game_id}/live/finish", ["game_id": gameID]), as: LiveStatus.self)
    }
}
