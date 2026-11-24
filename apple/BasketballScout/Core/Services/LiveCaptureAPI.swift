#if os(macOS)
import Foundation

/// The server calls a live capture makes (docs/LIVE.md "What a capture client does"). `APIClient` is the
/// real one; tests script a fake. A class, so a capture can tell the client a 401 came from apart from the
/// one the coach signed in with afterwards.
nonisolated protocol LiveCaptureAPI: AnyObject, Sendable {
    /// `POST /api/games/{id}/live` without a body: the server picks the part length. 200 for a game that is
    /// already capturing (the capture resumes with it).
    func startLive(gameID: String) async throws(APIError) -> LiveStatus
    /// `GET /api/games/{id}/live`: the game with its live state, read every few seconds while capturing so an
    /// end the server (or another device) decided is noticed at once.
    func liveStatus(gameID: String) async throws(APIError) -> LiveStatus
    /// `POST /api/games/{id}/live/segments`: the upload session of one part. `status == .complete`: the server
    /// has the part already; `.open` with `received > 0`: continue from there.
    func createLivePartUpload(gameID: String, _ body: LiveSegmentInit) async throws(APIError) -> UploadSession
    /// `PUT /api/uploads/{id}/chunk?offset=N`.
    func sendLivePartChunk(uploadID: String, offset: Int, data: Data) async throws(APIError) -> UploadSession
    /// `POST /api/uploads/{id}/complete`: the part joins the stream.
    func completeLivePartUpload(id: String) async throws(APIError) -> FilmResult
    /// `POST /api/games/{id}/live/finish`: no more film is coming.
    func finishLive(gameID: String) async throws(APIError) -> LiveStatus
}

nonisolated extension APIClient: LiveCaptureAPI {
    func startLive(gameID: String) async throws(APIError) -> LiveStatus {
        try await startLive(gameID: gameID, segmentSeconds: nil)
    }

    func createLivePartUpload(gameID: String, _ body: LiveSegmentInit) async throws(APIError) -> UploadSession {
        try await createLiveSegmentUpload(gameID: gameID, body)
    }

    func sendLivePartChunk(uploadID: String, offset: Int, data: Data) async throws(APIError) -> UploadSession {
        try await uploadChunk(uploadID: uploadID, offset: offset, data: data)
    }

    func completeLivePartUpload(id: String) async throws(APIError) -> FilmResult {
        try await completeUpload(id: id)
    }
}
#endif
