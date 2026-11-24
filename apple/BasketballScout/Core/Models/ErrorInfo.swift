import Foundation

/// The body of every server error, `{"error": ErrorInfo}` (01 §2.1), and `Game.error` / `Job.error`.
///
/// Branch on `code`, never on the HTTP status or `message` (01 §2.2): one status carries several codes,
/// `VALIDATION_FAILED` also arrives with 400 and 405, and codes are open-ended (a newer server may send
/// one this app does not know), so `code` is a plain `String`; `ErrorCode` has the known ones.
/// `retryable` is set per error, not per code. Show `title`, `message` and `hint` verbatim
/// (`Text(verbatim:)`: hints contain backticks and shell commands) and keep `detail` (server paths,
/// tracebacks) behind a "Technical details" disclosure (09 R25, R47).
nonisolated struct ErrorInfo: Codable, Hashable, Sendable, Error {
    var code: String
    var title: String
    var message: String
    var hint: String?
    var retryable: Bool
    var detail: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case title
        case message
        case hint
        case retryable
        case detail
    }

    init(code: String, title: String, message: String, hint: String? = nil, retryable: Bool = false, detail: String? = nil) {
        self.code = code
        self.title = title
        self.message = message
        self.hint = hint
        self.retryable = retryable
        self.detail = detail
    }

    /// The message as the web shows it: for `VALIDATION_FAILED` with a field list, `message + " " + detail`
    /// ("Some fields are invalid. scouted_team: Field required"), otherwise `message` (api.js:53).
    var displayMessage: String {
        if code == ErrorCode.validationFailed, let detail, !detail.isEmpty {
            return message + " " + detail
        }
        return message
    }
}
