import Foundation

/// A server `ErrorInfo` (as in `Job.error` and `Game.error`) can go straight into `ErrorBox`: title,
/// message and hint verbatim, `detail` (tracebacks, server paths) behind "Technical details", and
/// `retryable` as sent (01 §2.1, §2.8). Errors of HTTP calls arrive as `APIError`, which also adds the
/// `VALIDATION_FAILED` field list to the message.
nonisolated extension ErrorInfo: PresentableError {
    var isRetryable: Bool { retryable }
}
