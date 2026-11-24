import Foundation

/// One row of the System status panel (07 §3.8; 02 §9.3): label, value text, and whether the value is
/// judged good (green) or bad (red); rows that are not judged stay plain. The words always say the state,
/// so colour is never the only signal.
nonisolated struct SystemStatusRow: Hashable, Sendable, Identifiable {
    let label: String
    let value: String
    /// `.success` when good, `.danger` when not, nil when not judged.
    let tone: ScoutTone?

    var id: String { label }

    /// The web's eight rows in its order, then the two health fields the web does not show
    /// (`auth_enabled`, `max_upload_bytes`), so every field is visible.
    static func rows(for health: HealthStatus) -> [SystemStatusRow] {
        [
            SystemStatusRow(label: "Overall", value: health.status == .ok ? "OK" : "Needs attention", tone: judged(health.status == .ok)),
            SystemStatusRow(label: "Version", value: health.version, tone: nil),
            SystemStatusRow(label: "Video processor", value: health.processor, tone: nil),
            SystemStatusRow(label: "Job queue", value: health.queueText, tone: judged(health.queueOK)),
            SystemStatusRow(
                label: "Modal (GPU)", value: health.modalConfigured ? "Configured" : "Not configured",
                tone: judged(health.isModalOK)),
            SystemStatusRow(
                label: "Claude reports", value: health.claudeConfigured ? "Configured" : "Not configured",
                tone: judged(health.claudeConfigured)),
            SystemStatusRow(label: "Worker last seen", value: health.workerLastSeenText, tone: judged(health.isWorkerHealthy)),
            SystemStatusRow(label: "ffmpeg", value: health.ffmpegAvailable ? "Installed" : "Missing", tone: judged(health.ffmpegAvailable)),
            SystemStatusRow(label: "Sign-in", value: health.authEnabled ? "Password required" : "Off (no password)", tone: nil),
            SystemStatusRow(
                label: "Largest film", value: health.maxUploadBytes.map { ScoutFormat.bytes(Int64($0)) } ?? ScoutFormat.placeholder,
                tone: nil),
        ]
    }

    /// "OK" / "Needs attention" for a one-line summary.
    static func overall(for health: HealthStatus?) -> String {
        guard let health else { return ScoutFormat.placeholder }
        return health.status == .ok ? "OK" : "Needs attention"
    }

    private static func judged(_ isGood: Bool) -> ScoutTone {
        isGood ? .success : .danger
    }
}
