import Foundation

/// What the coach sees for each `APIError` (07 §4.7, §12; 01 §2.7; 02 §9.1, §11).
///
/// Server errors are shown verbatim (`ErrorBox` uses `Text(verbatim:)`): title, message (for
/// `VALIDATION_FAILED` "message detail", api.js:53), hint, and `detail` behind "Technical details". Hints
/// with shell commands go behind that disclosure as well (`PresentableError.technicalHint`, 09 R47).
/// Two middleware errors IT must fix get coach wording with the server's text as the detail
/// (02 §10 rule 5). Errors without server JSON use the web's fallback texts by status (api.js:30-41).
nonisolated extension APIError: PresentableError {
    var title: String {
        switch self {
        case .server(let info, _, _):
            switch info.code {
            case ErrorCode.authNotConfigured: "Sign-in isn't set up on the server"
            case ErrorCode.hostNotAllowed: "This server doesn't accept that name"
            default: info.title
            }
        case .unauthorized(let info): info?.title ?? "Please sign in"
        case .throttled(_, let info): info?.title ?? "Too many sign-in attempts"
        case .transport(let error): NetworkProblem(error).title
        case .notJSON(let status): Self.fallback(status: status).title
        case .decoding: "Unexpected server response"
        case .cancelled: "Cancelled"
        case .local(let failure):
            switch failure {
            case .encoding: "Couldn't send that"
            case .readingFile: "Couldn't read the file"
            case .savingFile: "Couldn't save the file"
            }
        }
    }

    var message: String {
        switch self {
        case .server(let info, _, _):
            switch info.code {
            case ErrorCode.authNotConfigured: "The server has no coaches' password yet."
            case ErrorCode.hostNotAllowed: "The server doesn't answer to the address this app uses for it."
            default: info.displayMessage
            }
        case .unauthorized(let info): info?.message ?? "The server asked for your username and password."
        case .throttled(let seconds, let info):
            info?.message ?? "Sign-in from this network is paused for about \(Self.minutesText(seconds))."
        case .transport(let error):
            NetworkProblem(error).message(host: Self.host(of: error), hostAndPort: Self.hostAndPort(of: error))
        case .notJSON(let status): Self.fallback(status: status).message
        case .decoding: "The server sent something the app could not read."
        case .cancelled: "The request was cancelled."
        case .local(let failure):
            switch failure {
            case .encoding: "The app could not prepare this request."
            case .readingFile(let name): "The app could not open “\(name)”."
            case .savingFile(let name): "The app could not save “\(name)” on this device."
            }
        }
    }

    var hint: String? {
        switch self {
        case .server(let info, _, _):
            switch info.code {
            case ErrorCode.authNotConfigured: "Ask IT to set SCOUT_AUTH_PASSWORD in .env and restart the web app."
            case ErrorCode.hostNotAllowed:
                "Use the server's IP address, or ask IT to add this name to SCOUT_ALLOWED_HOSTS and restart the web app."
            default: info.hint
            }
        case .unauthorized(let info): info == nil ? "Sign in again." : info?.hint
        case .throttled(_, let info):
            info?.hint ?? "Wait, then try again with the right password (check it with IT)."
        case .transport(let error):
            NetworkProblem(error).hint(plainHTTPAllowed: Self.allowsPlainHTTP(error))
        case .notJSON(let status): Self.fallback(status: status).hint
        case .decoding: "Try again. If it keeps happening, the app or the server may need an update."
        case .cancelled: nil
        case .local(let failure):
            switch failure {
            case .encoding: "Try again. If it keeps happening, quit and reopen the app."
            case .readingFile: "Pick the file again, or save a copy on this device first."
            case .savingFile: "Make sure this device has free space, then try again."
            }
        }
    }

    var detail: String? {
        switch self {
        case .server(let info, _, _):
            switch info.code {
            case ErrorCode.authNotConfigured, ErrorCode.hostNotAllowed:
                ServerText.sentences([info.message, info.detail])
            default:
                info.detail
            }
        case .unauthorized(let info), .throttled(_, let info): info?.detail
        case .transport(let error): "Network error \(error.code.rawValue)"
        case .notJSON(let status): "HTTP status \(status)"
        case .decoding(let status, let detail): "HTTP status \(status): \(detail)"
        case .cancelled: nil
        case .local(let failure):
            switch failure {
            case .encoding(let typeName): "Could not encode \(typeName)."
            case .readingFile, .savingFile: nil
            }
        }
    }

    var isRetryable: Bool {
        switch self {
        case .server(let info, _, _): info.retryable
        case .unauthorized, .throttled: false
        case .transport(let error): NetworkProblem(error).isRetryable
        case .notJSON(let status): Self.fallback(status: status).retryable
        case .decoding: true
        case .cancelled: true
        case .local(let failure): failure.isRetryable
        }
    }

    // MARK: - Helpers

    /// The web's texts for an error status without server JSON (api.js:30-41), plus redirects, which the
    /// app never follows.
    static func fallback(status: Int) -> (title: String, message: String, hint: String?, retryable: Bool) {
        switch status {
        case 300..<400:
            ("The server's address has changed",
             "The server sent the app to a different address.",
             "Sign out, then connect again with the address IT gave you.",
             false)
        case 401:
            ("Please sign in", "The server asked for your username and password.", "Sign in again.", false)
        case 413:
            ("Request too large",
             "The server refused a request that was too large.",
             "If the server runs behind nginx, raise client_max_body_size (see deploy/nginx).",
             false)
        case 502...504:
            ("Server unavailable",
             "The server is not responding right now (it may be restarting).",
             "Wait a moment and try again.",
             true)
        default:
            ("Unexpected error",
             "The server answered with status \(status).",
             "Try again; if it keeps happening check the server logs.",
             status >= 500)
        }
    }

    /// "1 minute", "5 minutes": `max(1, round(seconds / 60))`, as the server counts (02 §3.3).
    static func minutesText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.toNearestOrEven)))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static func host(of error: URLError) -> String {
        guard let url = error.failingURL, let host = url.host(percentEncoded: false), !host.isEmpty else {
            return "the server"
        }
        return host
    }

    private static func hostAndPort(of error: URLError) -> String {
        guard let url = error.failingURL, let host = url.host(percentEncoded: false), !host.isEmpty else {
            return "the server's address"
        }
        let scheme = url.scheme.flatMap { ServerAddress.Scheme(rawValue: $0.lowercased()) } ?? .http
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(shownHost):\(url.port ?? scheme.defaultPort)"
    }

    private static func allowsPlainHTTP(_ error: URLError) -> Bool {
        guard let host = error.failingURL?.host(percentEncoded: true) else { return false }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let parsed = try? ServerAddress.parseHost(bracketed) else { return false }
        return parsed.kind != .dotted
    }
}
