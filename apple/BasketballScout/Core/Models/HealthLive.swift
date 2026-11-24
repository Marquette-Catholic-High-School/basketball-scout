import Foundation

/// `GET /api/health/live` (no sign-in, no host check; 01 §4.1, 02 §8.1): exactly `{"status":"ok"}`. It only
/// proves the web process answers, not that the name or the password is accepted: call `/api/health` too.
nonisolated struct HealthLive: Codable, Hashable, Sendable {
    var status: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case status
    }

    var isOK: Bool { status == "ok" }
}
