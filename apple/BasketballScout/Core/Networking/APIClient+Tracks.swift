import Foundation

/// Player tracks and their manual assignments (05 §4.9–§4.11). Re-read `tracks(gameID:)` and compare the
/// track keys right before sending overrides: the server does not notice renumbered tracks (09 D1 #6).
nonisolated extension APIClient {
    /// `GET /api/games/{game_id}/tracks` → assignments of the last analysis (`[]` without one) and the
    /// current overrides.
    func tracks(gameID: String) async throws(APIError) -> TrackState {
        try await decoded(APIRequest(.get, "/api/games/{game_id}/tracks", ["game_id": gameID]), as: TrackState.self)
    }

    /// `PUT /api/games/{game_id}/tracks/{track_id}` → the stored override (the path's track id wins). 409
    /// while a full ANALYZE is queued or running; 422 when the player is not on that side's roster.
    func setTrackOverride(gameID: String, trackID: Int, _ body: TrackOverrideBody) async throws(APIError) -> TrackOverride {
        try await decoded(
            APIRequest(
                .put, "/api/games/{game_id}/tracks/{track_id}", ["game_id": gameID, "track_id": String(trackID)],
                body: APIRequest.json(body)),
            as: TrackOverride.self)
    }

    /// `DELETE /api/games/{game_id}/tracks/{track_id}` → 204 (back to automatic matching). A 404 "Track N
    /// has no manual assignment." means it is already gone; the web treats it as success (05 §4.11).
    func deleteTrackOverride(gameID: String, trackID: Int) async throws(APIError) {
        try await sendWithoutResult(
            APIRequest(.delete, "/api/games/{game_id}/tracks/{track_id}", ["game_id": gameID, "track_id": String(trackID)]))
    }
}
