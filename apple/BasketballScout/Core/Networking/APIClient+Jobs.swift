import Foundation

/// The processing queue and the scouting reports (03 §2.2, §2.3, §3; 09 C1–C3).
nonisolated extension APIClient {
    /// `POST /api/games/{game_id}/jobs` → 201, the queued job (`{"kind":"analyze"}`, `{"kind":"reanalyze"}`
    /// or a report with `coach_focus`). 409 while an analysis job is active; 503 `QUEUE_UNAVAILABLE`
    /// leaves a failed job row behind (09 C4).
    func startJob(gameID: String, _ body: JobCreate) async throws(APIError) -> Job {
        try await decoded(
            APIRequest(.post, "/api/games/{game_id}/jobs", ["game_id": gameID], body: APIRequest.json(body)),
            as: Job.self)
    }

    /// `GET /api/games/{game_id}/jobs` → at most 100 jobs of every kind, newest first. Take the job panel's
    /// job from here, not from `latest_job_id` (09 R33).
    func jobs(gameID: String) async throws(APIError) -> [Job] {
        try await decoded(APIRequest(.get, "/api/games/{game_id}/jobs", ["game_id": gameID]), as: [Job].self)
    }

    /// `GET /api/jobs/{job_id}`: poll every 3 s while the job is active.
    func job(id: String) async throws(APIError) -> Job {
        try await decoded(APIRequest(.get, "/api/jobs/{job_id}", ["job_id": id]), as: Job.self)
    }

    /// `POST /api/jobs/{job_id}/cancel` (no body) → 200, the same job: `cancelled` when it was queued,
    /// still `running` with `cancel_requested` until the worker stops it, unchanged when finished.
    func cancelJob(id: String) async throws(APIError) -> Job {
        try await decoded(APIRequest(.post, "/api/jobs/{job_id}/cancel", ["job_id": id]), as: Job.self)
    }

    /// `POST /api/jobs/{job_id}/retry` (no body) → 200, the NEW job (a failed ANALYZE past the GPU comes
    /// back as a REANALYZE). Only failed or cancelled jobs; otherwise 409.
    func retryJob(id: String) async throws(APIError) -> Job {
        try await decoded(APIRequest(.post, "/api/jobs/{job_id}/retry", ["job_id": id]), as: Job.self)
    }

    /// `POST /api/games/{game_id}/reports` → 202, a queued report job. The body is always an object
    /// (`{"coach_focus": null}` without a focus); the focus is trimmed by `ReportRequest` (09 D1 #3). The job
    /// does not name its report: reload `reports(gameID:)` after it succeeds (09 R30).
    func generateReport(gameID: String, _ body: ReportRequest = ReportRequest()) async throws(APIError) -> Job {
        try await decoded(
            APIRequest(.post, "/api/games/{game_id}/reports", ["game_id": gameID], body: APIRequest.json(body)),
            as: Job.self)
    }

    /// `GET /api/games/{game_id}/reports` → every report, newest first (each with its Markdown).
    func reports(gameID: String) async throws(APIError) -> [ReportRecord] {
        try await decoded(
            APIRequest(.get, "/api/games/{game_id}/reports", ["game_id": gameID], timeout: Timeout.heavy),
            as: [ReportRecord].self)
    }

    /// `GET /api/reports/{report_id}`.
    func report(id: String) async throws(APIError) -> ReportRecord {
        try await decoded(APIRequest(.get, "/api/reports/{report_id}", ["report_id": id]), as: ReportRecord.self)
    }

    /// `GET /api/games/{game_id}/export/report.md` → the report as Markdown, re-rendered with the current
    /// game details (`text/markdown; charset=utf-8`, 09 B14). `reportID` nil = the newest report.
    func reportMarkdown(gameID: String, reportID: String? = nil) async throws(APIError) -> String {
        try await text(reportMarkdownRequest(gameID: gameID, reportID: reportID, download: false))
    }

    /// The same Markdown as a file (`scouting_report_<team>_<date>.md`) for sharing or saving.
    func downloadReportMarkdown(gameID: String, reportID: String? = nil) async throws(APIError) -> DownloadedFile {
        try await download(
            reportMarkdownRequest(gameID: gameID, reportID: reportID, download: true),
            fallbackFilename: "scouting_report.md")
    }

    private func reportMarkdownRequest(gameID: String, reportID: String?, download: Bool) -> APIRequest {
        var query: [APIRequest.QueryItem] = []
        if let reportID, !reportID.isEmpty { query.append(.init("report_id", reportID)) }
        if download { query.append(.init("download", "1")) }
        return APIRequest(
            .get, "/api/games/{game_id}/export/report.md", ["game_id": gameID], query: query, accept: "*/*")
    }
}
