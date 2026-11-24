import Foundation

/// A processing job (01 §4.3, 03 §1.4): `POST /api/games/{id}/jobs` (201), `GET /api/games/{id}/jobs`
/// (≤ 100, newest first), `GET /api/jobs/{id}`, cancel and retry (200), `POST /api/games/{id}/reports`
/// (202) and `FilmResult.job`. Every key is always present.
///
/// Labels and the too-late-to-cancel rule are in `Labels.swift`; derived states in `Job+Derived.swift`.
nonisolated struct Job: Codable, Hashable, Sendable, Identifiable {
    /// `j_` + 12 lowercase hex.
    var id: String
    var gameID: String
    var kind: JobKind
    var status: JobStatus
    /// `done` after success or cancel; a failed job keeps the stage it failed at (09 B4 has the exception).
    var stage: JobStage
    /// Overall progress 0–100 (03 §3.2); not reset by a failure or a cancel.
    var progress: Double
    /// The server's live one-liner. Hide it once `cancelRequested` is set (09 D1 #10).
    var message: String
    /// Set when `status == .failed`.
    var error: ErrorInfo?
    /// Shown after success, e.g. late-cancel notes and "Scouting report not generated: …" (03 §3.5).
    var warnings: [String]
    /// Free-form; keys in use: `report` (Bool, REANALYZE writes a report afterwards) and `coach_focus`
    /// (String or null). Other keys are stored and echoed.
    var params: [String: JSONValue]
    /// Worker claims so far.
    var attempts: Int
    var maxAttempts: Int
    /// `modal` / `mock` / `local` for ANALYZE; null for the other kinds.
    var processor: String?
    /// Processor handle (Modal call id, `mock:<job id>`).
    var externalID: String?
    var cancelRequested: Bool
    /// `"<hostname>:<pid>"` of the worker; stays after the job ends.
    var workerID: String?
    /// Epoch seconds (a float, not an ISO string; 09 R21). Internal to the server.
    var leaseExpiresAt: Double?
    var createdAt: Date?
    /// First claim; kept across worker restarts. "running for …" starts here.
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case gameID = "game_id"
        case kind
        case status
        case stage
        case progress
        case message
        case error
        case warnings
        case params
        case attempts
        case maxAttempts = "max_attempts"
        case processor
        case externalID = "external_id"
        case cancelRequested = "cancel_requested"
        case workerID = "worker_id"
        case leaseExpiresAt = "lease_expires_at"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        gameID: String,
        kind: JobKind,
        status: JobStatus = .queued,
        stage: JobStage = .queued,
        progress: Double = 0,
        message: String = "",
        error: ErrorInfo? = nil,
        warnings: [String] = [],
        params: [String: JSONValue] = [:],
        attempts: Int = 0,
        maxAttempts: Int = 3,
        processor: String? = nil,
        externalID: String? = nil,
        cancelRequested: Bool = false,
        workerID: String? = nil,
        leaseExpiresAt: Double? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.gameID = gameID
        self.kind = kind
        self.status = status
        self.stage = stage
        self.progress = progress
        self.message = message
        self.error = error
        self.warnings = warnings
        self.params = params
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.processor = processor
        self.externalID = externalID
        self.cancelRequested = cancelRequested
        self.workerID = workerID
        self.leaseExpiresAt = leaseExpiresAt
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }
}
