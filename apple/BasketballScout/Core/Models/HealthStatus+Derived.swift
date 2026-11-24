import Foundation

// What the web computes from `GET /api/health` (07 §3.8, labels.js:158-173, index.js:115-155).

nonisolated extension HealthStatus {
    /// A heartbeat older than this means the worker has probably stopped (`WORKER_STALE_S`, labels.js:159;
    /// the server's `WORKER_STALE_AFTER_S`).
    static let workerStaleAfterSeconds: Double = 120

    /// Demo mode: `processor == "mock"` makes up results (09 R43).
    var isDemoMode: Bool { processor == "mock" }

    /// No worker heartbeat was ever seen.
    var isWorkerMissing: Bool { workerLastSeenS == nil }

    /// The newest heartbeat is older than 120 s.
    var isWorkerStale: Bool { (workerLastSeenS ?? 0) > Self.workerStaleAfterSeconds }

    /// The worker answers: seen within 120 s (the "Worker last seen" row is green).
    var isWorkerHealthy: Bool { !isWorkerMissing && !isWorkerStale }

    /// Modal is fine for this server: not the GPU processor, or configured (the "Modal (GPU)" row is green).
    var isModalOK: Bool { processor != "modal" || modalConfigured }

    /// "Worker last seen" value: "never", "45 s ago", "10 min ago", "2 h ago".
    var workerLastSeenText: String { Labels.ago(seconds: workerLastSeenS) }

    /// "Job queue" value: "<backend> OK" / "<backend> down".
    var queueText: String { "\(queueBackend) \(queueOK ? "OK" : "down")" }

    /// The notice when no worker takes queued jobs (`workerWarning`, labels.js:162-173); the job panel shows it
    /// under a queued job too. Nil when the worker answers.
    var workerNotice: NoticeText? {
        if workerLastSeenS == nil {
            return NoticeText(
                tone: .danger,
                title: "The background worker is not running - start basketball-scout-worker.",
                message: "On the server: sudo systemctl start basketball-scout-worker (or run python -m scout.worker). Film will wait in the queue until it runs.")
        }
        if isWorkerStale {
            return NoticeText(
                tone: .danger,
                title: "The background worker was last seen \(workerLastSeenText) - it may have stopped.",
                message: "Check it with: sudo systemctl status basketball-scout-worker")
        }
        return nil
    }

    /// The system status warnings in the web's order (`healthWarnings`, index.js:120-130): the bold text is
    /// the `title`, the muted line the `message`. Hints name server commands: show them verbatim.
    var notices: [NoticeText] {
        var notices: [NoticeText] = []
        if let workerNotice { notices.append(workerNotice) }
        if !queueOK {
            notices.append(NoticeText(
                tone: .danger,
                title: "The job queue (\(queueBackend)) is not reachable.",
                message: "Start Redis (sudo systemctl start redis-server) or set SCOUT_QUEUE_BACKEND=sqlite in .env."))
        }
        if processor == "modal" && !modalConfigured {
            notices.append(NoticeText(
                tone: .danger,
                title: "Modal (the GPU service) is not configured, so film cannot be analyzed.",
                message: "Run modal token new on the server (or set MODAL_TOKEN_ID / MODAL_TOKEN_SECRET in .env), then restart the worker."))
        }
        if isDemoMode {
            notices.append(NoticeText(
                tone: .info,
                title: "Demo mode: SCOUT_PROCESSOR=mock creates made-up results instead of analyzing the film.",
                message: "Set SCOUT_PROCESSOR=modal in .env for real analysis."))
        }
        if !claudeConfigured {
            notices.append(NoticeText(
                tone: .warning,
                title: "Claude is not configured, so scouting reports can't be written.",
                message: "Add ANTHROPIC_API_KEY to .env and restart the worker. Stats and exports still work."))
        }
        if !ffmpegAvailable {
            notices.append(NoticeText(
                tone: .warning,
                title: "ffmpeg is not installed on the server, so uploaded film can't be checked before processing.",
                message: "Install it with: sudo apt install ffmpeg"))
        }
        return notices
    }
}
