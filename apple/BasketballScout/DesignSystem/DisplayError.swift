import Foundation

/// A `PresentableError` built from plain strings: client-side checks ("Team name needed", "Not a
/// video file"), the web's client-made errors, and the fallback for unexpected errors.
nonisolated struct DisplayError: PresentableError, Hashable, Sendable {
    var title: String
    var message: String
    var hint: String?
    var detail: String?
    var isRetryable: Bool

    init(title: String, message: String, hint: String? = nil, detail: String? = nil, isRetryable: Bool = false) {
        self.title = title
        self.message = message
        self.hint = hint
        self.detail = detail
        self.isRetryable = isRetryable
    }

    /// The web's "Cancelled" error (a request the app abandoned).
    static let cancelled = DisplayError(title: "Cancelled", message: "The request was cancelled.", isRetryable: true)

    /// Anything thrown, ready to show (the web's `describeError`, `ui.js`): a `PresentableError`
    /// as it is, a cancellation as "Cancelled", anything else as "Something went wrong" with the
    /// error's description under the technical details (shown on screen only, never logged).
    static func describing(_ error: any Error) -> any PresentableError {
        if let presentable = error as? any PresentableError { return presentable }
        if error is CancellationError { return cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return cancelled }
        let description = String(String(describing: error).prefix(1000))
        return DisplayError(
            title: "Something went wrong",
            message: "An unexpected error occurred in the app.",
            hint: "Try again. If it keeps happening, quit and reopen the app.",
            detail: description.isEmpty ? nil : description,
            isRetryable: true
        )
    }
}
