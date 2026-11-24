import Foundation

/// An error the app can show: the server's `ErrorInfo` shape (title, message, hint, detail,
/// retryable), which every error box, notice and toast reads (07 §5.1, §12; 01 §2).
///
/// `APIError` (networking), upload and form errors conform. Show the strings verbatim
/// (`Text(verbatim:)`): server hints contain backticks and shell commands. `detail`, and hints with
/// shell commands, belong behind "Technical details (for IT staff)" (09 R25, R47); `ErrorBox` does
/// that for you.
nonisolated protocol PresentableError: Error {
    /// A few words: what happened ("Can't reach the server").
    var title: String { get }
    /// One plain sentence.
    var message: String { get }
    /// What to do next, or nil.
    var hint: String? { get }
    /// Technical detail for IT staff (tracebacks, field lists), or nil.
    var detail: String? { get }
    /// Whether trying the same thing again can help (drives "Try again" buttons and auto-retries).
    var isRetryable: Bool { get }
}

nonisolated extension PresentableError {
    var hint: String? { nil }
    var detail: String? { nil }
    var isRetryable: Bool { false }

    /// True when the hint is meant for the server administrator (shell commands, backticks), so it
    /// goes behind the technical details disclosure instead of under the message.
    var hintIsTechnical: Bool {
        guard let hint else { return false }
        return ServerText.isTechnical(hint)
    }

    /// The hint to show under the message (nil when empty or technical).
    var plainHint: String? {
        guard let hint = ServerText.nonEmpty(hint), !ServerText.isTechnical(hint) else { return nil }
        return hint
    }

    /// The technical hint for the disclosure (nil when empty or plain).
    var technicalHint: String? {
        guard let hint = ServerText.nonEmpty(hint), ServerText.isTechnical(hint) else { return nil }
        return hint
    }

    /// `detail` for the disclosure, unless it is empty or the message already contains it (a
    /// `VALIDATION_FAILED` message is shown as "message detail", 07 §4.7).
    var disclosedDetail: String? {
        guard let detail = ServerText.nonEmpty(detail) else { return nil }
        return message.contains(detail) ? nil : detail
    }

    /// Title and message in one line, for VoiceOver announcements and toasts.
    var spokenSummary: String {
        ServerText.sentences([title, message])
    }
}
