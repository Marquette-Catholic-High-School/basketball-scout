import Foundation

/// `HealthStatus.status` (02 §8.2): `degraded` when the queue is down, no worker heartbeat or one older
/// than 120 s, or the GPU processor has no Modal credentials. Claude and ffmpeg do not degrade it.
nonisolated enum HealthState: ServerEnum {
    case ok
    case degraded
    case unknown(String)

    static let knownCases: [HealthState] = [.ok, .degraded]

    var rawValue: String {
        switch self {
        case .ok: "ok"
        case .degraded: "degraded"
        case .unknown(let rawValue): rawValue
        }
    }
}
