import Foundation

/// Rosters of both teams, the import, single players and the template (05 §4.1–§4.8; 09 C5, R40, R42).
/// Every roster write deletes manual track assignments of players no longer on that roster (05 §6.6).
nonisolated extension APIClient {
    /// The largest roster file the server accepts (05 §4.4: 2 MB, 2,097,152 bytes allowed).
    static let maximumRosterFileBytes = 2 * 1024 * 1024

    /// `GET /api/games/{game_id}/rosters` → both rosters (a never-saved side has `updated_at: null`).
    func rosters(gameID: String) async throws(APIError) -> GameRosters {
        try await decoded(APIRequest(.get, "/api/games/{game_id}/rosters", ["game_id": gameID]), as: GameRosters.self)
    }

    /// `GET /api/games/{game_id}/rosters/{side}`.
    func roster(gameID: String, side: TeamSide) async throws(APIError) -> Roster {
        try await decoded(
            APIRequest(.get, "/api/games/{game_id}/rosters/{side}", ["game_id": gameID, "side": side.rawValue]),
            as: Roster.self)
    }

    /// `PUT /api/games/{game_id}/rosters/{side}` → the saved roster with generated ids. Replaces the whole
    /// list; last writer wins (no versioning, 05 §6.8).
    func replaceRoster(gameID: String, side: TeamSide, _ body: RosterReplace) async throws(APIError) -> Roster {
        try await decoded(
            APIRequest(
                .put, "/api/games/{game_id}/rosters/{side}", ["game_id": gameID, "side": side.rawValue],
                body: APIRequest.json(body)),
            as: Roster.self)
    }

    /// `POST /api/games/{game_id}/rosters/{side}/import`: multipart with the `file` part (named with its
    /// extension: `.csv`, `.tsv`, `.txt` or `.xlsx`; the server picks the parser by it) and `mode` as a
    /// FORM FIELD (09 D1 #7). Saves at once. Files over 2 MB are refused here with the server's own error
    /// (413 `UPLOAD_TOO_LARGE`) without sending them.
    func importRoster(
        gameID: String, side: TeamSide, fileData: Data, filename: String, mode: RosterImportMode
    ) async throws(APIError) -> RosterImportResult {
        guard fileData.count <= Self.maximumRosterFileBytes else {
            throw .server(
                ErrorInfo(
                    code: ErrorCode.uploadTooLarge, title: "File too large",
                    message: "Roster files must be 2 MB or smaller.", hint: "Save just the roster as a CSV."),
                status: 413)
        }
        let partFilename = Self.rosterUploadFilename(filename)
        var form = MultipartFormData()
        form.addFile(
            name: "file", filename: partFilename,
            contentType: MultipartFormData.contentType(forFilename: partFilename), data: fileData)
        form.addField(name: "mode", value: mode.rawValue)
        return try await decoded(
            APIRequest(
                .post, "/api/games/{game_id}/rosters/{side}/import", ["game_id": gameID, "side": side.rawValue],
                body: .multipart(form.body, boundary: form.boundary)),
            as: RosterImportResult.self)
    }

    /// Imports the file at `fileURL` (a picked file: security-scoped access is started and stopped here),
    /// sent under its own name. The file is read off the main actor.
    @concurrent
    func importRoster(gameID: String, side: TeamSide, fileURL: URL, mode: RosterImportMode) async throws(APIError) -> RosterImportResult {
        let filename = fileURL.lastPathComponent
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw .local(.readingFile(filename))
        }
        return try await importRoster(gameID: gameID, side: side, fileData: data, filename: filename, mode: mode)
    }

    /// `POST /api/games/{game_id}/rosters/{side}/players` → the whole roster (200). Leave `id` out so the
    /// server makes one (09 R42); a duplicate id is a 409.
    func addPlayer(gameID: String, side: TeamSide, _ player: RosterPlayerInput) async throws(APIError) -> Roster {
        try await decoded(
            APIRequest(
                .post, "/api/games/{game_id}/rosters/{side}/players", ["game_id": gameID, "side": side.rawValue],
                body: APIRequest.json(player)),
            as: Roster.self)
    }

    /// `PATCH /api/games/{game_id}/rosters/{side}/players/{player_id}` → the whole roster. Only set keys are
    /// sent; names are never null (05 §4.6).
    func updatePlayer(gameID: String, side: TeamSide, playerID: String, _ patch: RosterPlayerPatch) async throws(APIError) -> Roster {
        try await decoded(
            APIRequest(
                .patch, "/api/games/{game_id}/rosters/{side}/players/{player_id}",
                ["game_id": gameID, "side": side.rawValue, "player_id": playerID], body: APIRequest.json(patch)),
            as: Roster.self)
    }

    /// `DELETE /api/games/{game_id}/rosters/{side}/players/{player_id}` → 200 with the whole roster (not 204).
    func deletePlayer(gameID: String, side: TeamSide, playerID: String) async throws(APIError) -> Roster {
        try await decoded(
            APIRequest(
                .delete, "/api/games/{game_id}/rosters/{side}/players/{player_id}",
                ["game_id": gameID, "side": side.rawValue, "player_id": playerID]),
            as: Roster.self)
    }

    /// The name the file part carries: its last path component, which must have an extension because the
    /// server picks the parser by it (09 D1 #7). A name without one gets `.csv`, which the server reads as
    /// CSV, or as Excel when the bytes are a workbook (05 §4.4); an empty name becomes `roster.csv`, the
    /// server's own default.
    static func rosterUploadFilename(_ filename: String) -> String {
        let name = MultipartFormData.lastPathComponent(filename).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "." else { return "roster.csv" }
        return (name as NSString).pathExtension.isEmpty ? name + ".csv" : name
    }

    /// `GET /api/roster-template.csv` → `roster-template.csv` (needs sign-in like everything else, so a
    /// plain link would not work; 05 §9.6).
    func downloadRosterTemplate() async throws(APIError) -> DownloadedFile {
        try await download(
            APIRequest(.get, "/api/roster-template.csv", accept: "*/*"), fallbackFilename: "roster-template.csv")
    }
}
