import Foundation

/// Everything an `APIClient` call can fail with (01 §2, 02 §9.1, 07 §4.7, 09 R25).
///
/// Branch on the server's `code`, not on the status: one status carries several codes, and
/// `VALIDATION_FAILED` comes with 400, 405 and 422 (01 §2.2). Every area passes these errors through
/// `ServerSession.report(_:)` first, which applies the lockout gate (09 R6):
/// - `unauthorized`: a 401. Stop every request, poller and upload for the server and ask for the password.
///   Never retry it (each retry with a wrong password counts toward the school-wide lockout).
/// - `throttled`: a 429 `AUTH_THROTTLED`. Stop everything until `retryAfter` has passed. A 429 with another
///   code (`REPORT_RATE_LIMITED`) is an ordinary `server` error.
/// - `stopsAllRequests` also covers 503 `AUTH_NOT_CONFIGURED` and 403 `HOST_NOT_ALLOWED` (02 §10 rule 5).
nonisolated enum APIError: Error, Hashable, Sendable {
    /// The server's own error body, `{"error": ErrorInfo, "upload"?: UploadSession}`, with the HTTP status.
    /// `upload` comes with two chunk 409s and is the resume point (04 §2.4).
    case server(ErrorInfo, status: Int, upload: UploadSession? = nil)
    /// 401: the server did not accept the username and password (or a proxy asked for others). The
    /// server's `AUTH_REQUIRED` body when there was one.
    case unauthorized(ErrorInfo?)
    /// 429 `AUTH_THROTTLED`: too many wrong passwords from this network or device. Sign-in is paused for
    /// `retryAfter` seconds (the `Retry-After` header; 300, the full lockout, if it was missing).
    case throttled(retryAfter: TimeInterval, info: ErrorInfo?)
    /// The request got no HTTP answer: offline, DNS, refused, timed out, TLS, ATS, Local Network denied.
    case transport(URLError)
    /// An error status whose body is not the server's JSON: nginx's HTML 413/502/504, an empty 400/416,
    /// a redirect (3xx; redirects are never followed).
    case notJSON(status: Int)
    /// A 2xx answer the app could not read as the expected model (the web's `BAD_RESPONSE`). `detail` names
    /// the place (keys and indexes only, never values).
    case decoding(status: Int, detail: String)
    /// The task was cancelled (the screen went away, a newer request replaced it).
    case cancelled
    /// The app could not prepare the request or keep the answer; nothing (or not everything) reached the
    /// server.
    case local(LocalFailure)

    nonisolated enum LocalFailure: Hashable, Sendable {
        /// A request body could not be encoded (the type's name).
        case encoding(String)
        /// A picked file could not be read (the file name).
        case readingFile(String)
        /// A download could not be saved on this device (the file name).
        case savingFile(String)

        /// Saving can work on a second try (space freed); encoding and reading need a change first.
        var isRetryable: Bool {
            if case .savingFile = self { return true }
            return false
        }
    }
}

// MARK: - Facts for the lockout gate, pollers and screens

nonisolated extension APIError {
    /// A 401: the password is wrong or was changed. Stop everything and show sign-in (09 R6).
    var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// A 429 `AUTH_THROTTLED`: sign-in from this network is paused (09 R6).
    var isThrottle: Bool {
        if case .throttled = self { return true }
        return false
    }

    /// Seconds to wait before signing in again (throttle only).
    var retryAfter: TimeInterval? {
        if case .throttled(let seconds, _) = self { return seconds }
        return nil
    }

    /// Every request to this server must stop until the coach or IT acts: 401, 429 `AUTH_THROTTLED`,
    /// 503 `AUTH_NOT_CONFIGURED` and 403 `HOST_NOT_ALLOWED` (02 §10 rules 3–5).
    var stopsAllRequests: Bool {
        switch self {
        case .unauthorized, .throttled:
            return true
        case .server(let info, _, _):
            return info.code == ErrorCode.authNotConfigured || info.code == ErrorCode.hostNotAllowed
        default:
            return false
        }
    }

    /// The task was cancelled: not an error to show, and never retried automatically.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// The HTTP status, when the server answered.
    var status: Int? {
        switch self {
        case .server(_, let status, _), .notJSON(let status), .decoding(let status, _): status
        case .unauthorized: 401
        case .throttled: 429
        case .transport, .cancelled, .local: nil
        }
    }

    /// The server's own error body, when there was one.
    var serverInfo: ErrorInfo? {
        switch self {
        case .server(let info, _, _): info
        case .unauthorized(let info): info
        case .throttled(_, let info): info
        default: nil
        }
    }

    /// The error code: the server's, or the one the web builds on the client (01 §2.7): `NETWORK_ERROR`,
    /// `AUTH_REQUIRED`, `UPLOAD_TOO_LARGE` (non-JSON 413), `SERVER_UNAVAILABLE`, `HTTP_<status>`,
    /// `BAD_RESPONSE`; `CANCELLED` and `CLIENT_ERROR` for the app's own cases.
    var code: String {
        switch self {
        case .server(let info, _, _): info.code
        case .unauthorized(let info): info?.code ?? ErrorCode.authRequired
        case .throttled(_, let info): info?.code ?? ErrorCode.authThrottled
        case .transport: ErrorCode.networkError
        case .notJSON(let status):
            switch status {
            case 413: ErrorCode.uploadTooLarge
            case 502...504: ErrorCode.serverUnavailable
            default: "HTTP_\(status)"
            }
        case .decoding: ErrorCode.badResponse
        case .cancelled: "CANCELLED"
        case .local: "CLIENT_ERROR"
        }
    }

    /// The resume point a chunk 409 carries (04 §2.4: offset conflict, idle chunk).
    var upload: UploadSession? {
        if case .server(_, _, let upload) = self { return upload }
        return nil
    }

    /// 404 `NOT_FOUND` or `UPLOAD_NOT_FOUND`.
    var isNotFound: Bool {
        code == ErrorCode.notFound || code == ErrorCode.uploadNotFound
    }

    /// The URLError behind a transport failure.
    var urlError: URLError? {
        if case .transport(let error) = self { return error }
        return nil
    }

    /// The error in the server's `ErrorInfo` shape, built like the web for client-side cases (01 §2.7).
    var asErrorInfo: ErrorInfo {
        if case .server(let info, _, _) = self { return info }
        return ErrorInfo(code: code, title: title, message: message, hint: hint, retryable: isRetryable, detail: detail)
    }
}
