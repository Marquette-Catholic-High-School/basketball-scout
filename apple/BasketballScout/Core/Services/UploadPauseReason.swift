import Foundation

/// Why an upload is paused.
nonisolated enum UploadPauseReason: String, Sendable, Hashable, Codable {
    /// The coach pressed Pause (or the session is still being created): Resume continues it.
    case user
    /// The server stopped accepting this device's requests (wrong password, lockout; 09 R6): it
    /// continues after signing in again (`UploadManager.resumePendingUploads()`).
    case signedOut
    /// iOS: the app's background time ran out; it continues when the app is active again.
    case background
    /// Found after a relaunch, not running yet (it was paused, or its file needs checking).
    case interrupted

    /// The status line.
    var statusText: String {
        switch self {
        case .user, .interrupted: "Paused"
        case .signedOut: "Paused until you sign in again"
        case .background: "Paused while the app is in the background"
        }
    }
}
