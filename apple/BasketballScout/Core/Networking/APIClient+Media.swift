import Foundation

/// Film playback URL and court calibration (04 §4, §5).
nonisolated extension APIClient {
    /// `GET /api/games/{game_id}/video?variant=…`: the film for the resource loader (09 R11). Every request
    /// needs `authorizedRequest(_:)` plus a `Range` header; the answer is always labelled `video/mp4`
    /// (also for a .mov original) and the URL stays the same after a re-run, so rebuild the player item
    /// (09 R12). Never HEAD (405).
    func videoURL(gameID: String, variant: VideoVariant = .original) -> URL {
        let request = APIRequest(
            .get, "/api/games/{game_id}/video", ["game_id": gameID], query: [.init("variant", variant.rawValue)])
        return urlRequest(for: request).url ?? address.origin
    }

    /// `PUT /api/games/{game_id}/calibration` → the fitted calibration. Send `px` in the pixels of the copy
    /// that was shown, with its `video_width`/`video_height` (09 D1 #11). Allowed while a job runs.
    func saveCalibration(gameID: String, _ body: CalibrationRequest) async throws(APIError) -> CourtCalibration {
        try await decoded(
            APIRequest(.put, "/api/games/{game_id}/calibration", ["game_id": gameID], body: APIRequest.json(body)),
            as: CourtCalibration.self)
    }

    /// `DELETE /api/games/{game_id}/calibration` → 204, also when none was saved.
    func deleteCalibration(gameID: String) async throws(APIError) {
        try await sendWithoutResult(APIRequest(.delete, "/api/games/{game_id}/calibration", ["game_id": gameID]))
    }
}
