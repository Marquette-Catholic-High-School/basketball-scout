import Foundation

/// How answers and failures become `APIError`s (01 §2.7, 02 §9.1 and §10 rule 7, 09 R25).
nonisolated extension APIError {
    /// The lockout length (02 §4) when a 429 `AUTH_THROTTLED` comes without `Retry-After`.
    static let defaultThrottleSeconds: TimeInterval = 300

    /// An answer outside 2xx.
    ///
    /// "Our JSON" is a body that decodes as the error envelope with a non-empty `error.title`, as the web
    /// decides (api.js:51); anything else (nginx HTML, an empty 400 or 416, a redirect) falls back by status.
    /// Every 401 is `unauthorized`; a 429 is `throttled` only with code `AUTH_THROTTLED`.
    static func from(status: Int, headers: HTTPHeaders, body: Data) -> APIError {
        let envelope = serverEnvelope(in: body)
        if status == 401 { return .unauthorized(envelope?.error) }
        guard let envelope else { return .notJSON(status: status) }
        if status == 429, envelope.error.code == ErrorCode.authThrottled {
            let seconds = RetryAfter.seconds(from: headers.retryAfter) ?? defaultThrottleSeconds
            return .throttled(retryAfter: seconds, info: envelope.error)
        }
        return .server(envelope.error, status: status, upload: envelope.upload)
    }

    /// The server's error envelope, or nil when the body is not its JSON. A malformed `upload` sibling does
    /// not hide the error itself.
    static func serverEnvelope(in body: Data) -> ErrorEnvelope? {
        guard !body.isEmpty else { return nil }
        let decoder = ScoutJSON.decoder()
        let envelope: ErrorEnvelope
        if let full = try? decoder.decode(ErrorEnvelope.self, from: body) {
            envelope = full
        } else if let errorOnly = try? decoder.decode(ErrorOnlyEnvelope.self, from: body) {
            envelope = ErrorEnvelope(error: errorOnly.error)
        } else {
            return nil
        }
        guard !envelope.error.title.isEmpty else { return nil }
        return envelope
    }

    /// An error thrown by URLSession, or the task's cancellation. The URLError gets the request's URL as
    /// `failingURL` when it lacks one, so its message can name the server.
    static func from(transportError error: any Error, url: URL?) -> APIError {
        if error is CancellationError { return .cancelled }
        let urlError: URLError
        if let known = error as? URLError {
            urlError = known
        } else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else {
                return .transport(URLError(.unknown, userInfo: failingURLInfo(url)))
            }
            urlError = URLError(URLError.Code(rawValue: nsError.code), userInfo: nsError.userInfo)
        }
        if urlError.code == .cancelled { return .cancelled }
        guard urlError.failingURL == nil, let url else { return .transport(urlError) }
        var userInfo = urlError.userInfo
        userInfo.merge(failingURLInfo(url)) { current, _ in current }
        return .transport(URLError(urlError.code, userInfo: userInfo))
    }

    /// A 2xx body that did not decode (the web's `BAD_RESPONSE`). The detail names the place, never values.
    static func from(decodingError error: any Error, status: Int) -> APIError {
        .decoding(status: status, detail: describe(error))
    }

    /// Where decoding failed, as `key[index].key`: keys and indexes only, so no name or text from the body
    /// reaches the screen or a log.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "The answer is not valid JSON." }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing “\(key.stringValue)” at \(codingPath(context.codingPath))."
        case .valueNotFound(_, let context):
            return "Missing value at \(codingPath(context.codingPath))."
        case .typeMismatch(_, let context):
            return "Unexpected type at \(codingPath(context.codingPath))."
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "The answer is not valid JSON."
                : "Unreadable value at \(codingPath(context.codingPath))."
        @unknown default:
            return "The answer could not be read."
        }
    }

    static func codingPath(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "the top level" }
        var text = ""
        for key in path {
            if let index = key.intValue, key.stringValue.hasPrefix("Index") || key.stringValue == String(index) {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return text
    }

    private static func failingURLInfo(_ url: URL?) -> [String: Any] {
        guard let url else { return [:] }
        return [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString]
    }
}

/// `{"error": ErrorInfo}` alone, for bodies whose `upload` sibling does not decode.
private nonisolated struct ErrorOnlyEnvelope: Decodable {
    var error: ErrorInfo
}
