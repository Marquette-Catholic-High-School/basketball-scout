import Foundation

/// `GET /api/health` (signed in; 01 §4.1, 02 §8.2): what works on the server. Cheap to call; the web asks at
/// most every 15 s while a job waits in the queue.
nonisolated struct HealthStatus: Codable, Hashable, Sendable {
    var status: HealthState
    /// The server version (currently "0.1.0"); there is no API versioning (09 R9).
    var version: String
    /// `modal`, `mock` (demo results) or `local`.
    var processor: String
    /// `sqlite` or `redis`.
    var queueBackend: String
    var queueOK: Bool
    var modalConfigured: Bool
    /// False: scouting reports cannot be written.
    var claudeConfigured: Bool
    var ffmpegAvailable: Bool
    /// Seconds since the newest worker heartbeat (1 decimal); nil = never seen. Computed on the server, so
    /// no device clock skew.
    var workerLastSeenS: Double?
    var authEnabled: Bool
    /// The upload size limit (default 12 GiB = 12884901888); null only in theory.
    var maxUploadBytes: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case version
        case processor
        case queueBackend = "queue_backend"
        case queueOK = "queue_ok"
        case modalConfigured = "modal_configured"
        case claudeConfigured = "claude_configured"
        case ffmpegAvailable = "ffmpeg_available"
        case workerLastSeenS = "worker_last_seen_s"
        case authEnabled = "auth_enabled"
        case maxUploadBytes = "max_upload_bytes"
    }

    init(
        status: HealthState = .ok,
        version: String,
        processor: String,
        queueBackend: String,
        queueOK: Bool = true,
        modalConfigured: Bool = false,
        claudeConfigured: Bool = false,
        ffmpegAvailable: Bool = false,
        workerLastSeenS: Double? = nil,
        authEnabled: Bool = true,
        maxUploadBytes: Int? = nil
    ) {
        self.status = status
        self.version = version
        self.processor = processor
        self.queueBackend = queueBackend
        self.queueOK = queueOK
        self.modalConfigured = modalConfigured
        self.claudeConfigured = claudeConfigured
        self.ffmpegAvailable = ffmpegAvailable
        self.workerLastSeenS = workerLastSeenS
        self.authEnabled = authEnabled
        self.maxUploadBytes = maxUploadBytes
    }
}
