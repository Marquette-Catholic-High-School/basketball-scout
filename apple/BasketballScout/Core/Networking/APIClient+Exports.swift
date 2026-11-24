import Foundation

/// The game's exports (03 §2.4, §6). Each needs a finished analysis (409 `ANALYSIS_NOT_READY` otherwise).
/// Downloads ask with `download=1` so the server names the file (`<prefix>_<team-slug>_<date>.<ext>`).
nonisolated extension APIClient {
    /// `GET …/export/fastscout.txt?side=`: the FastScout paste block (tab-separated, `\n`, no trailing
    /// newline) for the preview and the clipboard. Treat it as opaque text: columns come from server config.
    func fastScoutText(gameID: String, side: TeamSide = .scouted) async throws(APIError) -> String {
        try await text(fastScoutTextRequest(gameID: gameID, side: side, download: false))
    }

    /// The paste block as `fastscout_<team>_<date>.txt`.
    func downloadFastScoutText(gameID: String, side: TeamSide = .scouted) async throws(APIError) -> DownloadedFile {
        try await download(fastScoutTextRequest(gameID: gameID, side: side, download: true), fallbackFilename: "fastscout.txt")
    }

    /// `GET …/export/fastscout-notes?side=` → warnings to check before pasting and the team numbers to type
    /// in by hand.
    func fastScoutNotes(gameID: String, side: TeamSide = .scouted) async throws(APIError) -> FastScoutNotes {
        try await decoded(
            APIRequest(
                .get, "/api/games/{game_id}/export/fastscout-notes", ["game_id": gameID],
                query: [.init("side", side.rawValue)]),
            as: FastScoutNotes.self)
    }

    /// `GET /api/export/fastscout/tables` → the custom-table names in config order (default
    /// `box, zones, plays, defense`).
    func fastScoutTables() async throws(APIError) -> [String] {
        try await decoded(APIRequest(.get, "/api/export/fastscout/tables"), as: [String].self)
    }

    /// `GET …/export/fastscout.csv?side=&table=&download=1` → `fastscout[_<table>]_<team>_<date>.csv`
    /// (CRLF). `table` nil or empty = the server's default table.
    func downloadFastScoutCSV(gameID: String, side: TeamSide = .scouted, table: String? = nil) async throws(APIError) -> DownloadedFile {
        var query: [APIRequest.QueryItem] = [.init("side", side.rawValue)]
        var fallback = "fastscout.csv"
        if let table, !table.isEmpty {
            query.append(.init("table", table))
            fallback = ContentDisposition.sanitizedFilename("fastscout_\(table).csv") ?? fallback
        }
        query.append(.init("download", "1"))
        return try await download(
            APIRequest(.get, "/api/games/{game_id}/export/fastscout.csv", ["game_id": gameID], query: query, accept: "*/*"),
            fallbackFilename: fallback)
    }

    /// `GET …/export/timeline.csv?download=1` → `timeline_<team>_<date>.csv`.
    func downloadTimelineCSV(gameID: String) async throws(APIError) -> DownloadedFile {
        try await download(
            APIRequest(
                .get, "/api/games/{game_id}/export/timeline.csv", ["game_id": gameID],
                query: [.init("download", "1")], accept: "*/*"),
            fallbackFilename: "timeline.csv")
    }

    /// `GET …/export/analysis.json?download=1` → `analysis_<team>_<date>.json` (indented, several MB).
    func downloadAnalysisJSON(gameID: String) async throws(APIError) -> DownloadedFile {
        try await download(
            APIRequest(
                .get, "/api/games/{game_id}/export/analysis.json", ["game_id": gameID],
                query: [.init("download", "1")], timeout: Timeout.heavy, accept: "*/*"),
            fallbackFilename: "analysis.json")
    }

    private func fastScoutTextRequest(gameID: String, side: TeamSide, download: Bool) -> APIRequest {
        var query: [APIRequest.QueryItem] = [.init("side", side.rawValue)]
        if download { query.append(.init("download", "1")) }
        return APIRequest(.get, "/api/games/{game_id}/export/fastscout.txt", ["game_id": gameID], query: query, accept: "*/*")
    }
}
