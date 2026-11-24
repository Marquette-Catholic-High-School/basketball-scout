import Foundation

/// Games and their analysis (03 §2.1, 06 §1.1).
nonisolated extension APIClient {
    /// `GET /api/games` → every game, newest first, no paging.
    func games() async throws(APIError) -> [Game] {
        try await decoded(APIRequest(.get, "/api/games"), as: [Game].self)
    }

    /// `POST /api/games` → 201, the new game (`draft`). Not idempotent: after a transport error, re-read the
    /// list before trying again (09 C11).
    func createGame(_ body: GameCreate) async throws(APIError) -> Game {
        try await decoded(APIRequest(.post, "/api/games", body: APIRequest.json(body)), as: Game.self)
    }

    /// `GET /api/games/{game_id}`.
    func game(id: String) async throws(APIError) -> Game {
        try await decoded(APIRequest(.get, "/api/games/{game_id}", ["game_id": id]), as: Game.self)
    }

    /// `PATCH /api/games/{game_id}`: only the keys that are set are sent and changed (`{}` when none).
    /// A `team_id_map` or `scouted_color` change takes effect at the next analysis (03 §2.1).
    func updateGame(id: String, _ update: GameUpdate) async throws(APIError) -> Game {
        try await decoded(
            APIRequest(.patch, "/api/games/{game_id}", ["game_id": id], body: APIRequest.json(update)),
            as: Game.self)
    }

    /// `DELETE /api/games/{game_id}` → 204. Allowed at any time; cancels the game's jobs and removes film,
    /// results, rosters and reports. A second call is a 404.
    func deleteGame(id: String) async throws(APIError) {
        try await sendWithoutResult(APIRequest(.delete, "/api/games/{game_id}", ["game_id": id]))
    }

    /// `GET /api/games/{game_id}/analysis` → the whole analysis (1–5 MB, no gzip, no ETag; 09 R27), decoded
    /// off the main actor with a 120 s timeout. 409 `ANALYSIS_NOT_READY` means "no analysis (yet)", which
    /// the web does not show as an error (01 §2.8; 09 C9).
    func analysis(gameID: String) async throws(APIError) -> GameAnalysis {
        try await decoded(
            APIRequest(.get, "/api/games/{game_id}/analysis", ["game_id": gameID], timeout: Timeout.heavy),
            as: GameAnalysis.self)
    }
}
