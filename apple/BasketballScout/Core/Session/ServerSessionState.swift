import Foundation

/// Where the app stands with its server (DESIGN §4, §6 [C]; 02 §10–§11; 09 R6).
///
/// - `signedOut`: no usable sign-in. The sign-in screen is shown (prefilled from the last server, with
///   `ServerSession.problem` when the server refused every request).
/// - `checking`: the launch check runs: ONE signed-in `GET /api/health` before anything else is sent
///   (02 §10 rule 2).
/// - `signedIn`: requests may be sent (`ServerSession.client` is set).
/// - `locked(until:)`: the server answered 429 `AUTH_THROTTLED`; nothing is sent until `until` (countdown).
/// - `needsPassword(message:)`: the server answered 401 to the saved password; nothing is sent until the
///   coach types it again.
nonisolated enum ServerSessionState: Hashable, Sendable {
    case signedOut
    case checking
    case signedIn
    case locked(until: Date)
    case needsPassword(message: String?)

    /// Requests may be sent.
    var isSignedIn: Bool { self == .signedIn }

    /// The end of a lockout, if this is one.
    var lockedUntil: Date? {
        if case .locked(let until) = self { return until }
        return nil
    }
}

/// Why `ServerSession` stopped every request (passed to `ServerSession.onStopAll`).
nonisolated enum ServerSessionStopReason: Hashable, Sendable {
    /// The coach signed out.
    case signedOut
    /// 401 to a request that carried the saved password (09 R6).
    case passwordRejected
    /// 429 `AUTH_THROTTLED` (09 R6).
    case throttled
    /// 403 `HOST_NOT_ALLOWED` or 503 `AUTH_NOT_CONFIGURED`: IT must act (02 §10 rule 5).
    case refusedByServer
}
