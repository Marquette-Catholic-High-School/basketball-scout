import Foundation

/// One API call as data: method, route, path parameters, query, body and timeout. `APIClient` turns it
/// into a `URLRequest` (`APIClient.urlRequest(for:)`), so tests can check the exact request shape.
nonisolated struct APIRequest: Sendable {
    /// What goes in the body, with the Content-Type it gets.
    nonisolated enum Body: Hashable, Sendable {
        /// No body and no Content-Type (GET, DELETE, cancel, retry, complete).
        case none
        /// `Content-Type: application/json`, always explicit (09 B3: a JSON body without it is a 422).
        case json(Data)
        /// `Content-Type: application/octet-stream`: raw film bytes of a chunk PUT (04 §2.4).
        case octetStream(Data)
        /// `Content-Type: multipart/form-data; boundary=…` (roster import, 05 §4.4).
        case multipart(Data, boundary: String)
    }

    nonisolated struct QueryItem: Hashable, Sendable {
        var name: String
        var value: String

        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    var method: HTTPMethod
    /// The route as documented, e.g. `/api/games/{game_id}/rosters/{side}` (the 08 manifest's
    /// `endpoint`). Logged instead of the path, so no id or name reaches the log.
    var route: String
    /// The percent-encoded path, parameters filled in.
    var path: String
    var query: [QueryItem]
    var body: Body
    /// Idle timeout of this request (seconds).
    var timeout: TimeInterval
    /// Every route but `/api/health/live` needs `Authorization` (02 §3.1).
    var sendsCredentials: Bool
    /// `application/json` for JSON answers; `*/*` for text and file downloads (what the web sends).
    var accept: String

    /// - Parameters:
    ///   - route: the documented path with `{name}` placeholders.
    ///   - parameters: the placeholder values; each is percent-encoded as one path segment.
    init(
        _ method: HTTPMethod,
        _ route: String,
        _ parameters: [String: String] = [:],
        query: [QueryItem] = [],
        body: Body = .none,
        timeout: TimeInterval = APIClient.Timeout.standard,
        sendsCredentials: Bool = true,
        accept: String = "application/json"
    ) {
        self.method = method
        self.route = route
        self.path = Self.expand(route, parameters)
        self.query = query
        self.body = body
        self.timeout = timeout
        self.sendsCredentials = sendsCredentials
        self.accept = accept
    }

    /// `query` as `name=value&…`, both percent-encoded strictly (only unreserved characters stay), so a
    /// `+`, `&` or `=` in a value (a custom FastScout table name) reaches the server unchanged.
    var percentEncodedQuery: String? {
        guard !query.isEmpty else { return nil }
        return query.map { Self.percentEncode($0.name) + "=" + Self.percentEncode($0.value) }.joined(separator: "&")
    }

    /// The JSON body for `value`, encoded with `ScoutJSON.encoder()` (models carry the exact wire keys).
    static func json<T: Encodable>(_ value: T) throws(APIError) -> Body {
        do {
            return .json(try ScoutJSON.encode(value))
        } catch {
            throw .local(.encoding(String(describing: type(of: value))))
        }
    }

    // MARK: - Encoding helpers

    /// Fills `{name}` placeholders of `route` with percent-encoded `parameters` (ids are URL-encoded as the
    /// web does, 01 §1.7; player ids are client-chosen strings, 05 §2).
    static func expand(_ route: String, _ parameters: [String: String]) -> String {
        route.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return String(segment) }
            let name = String(segment.dropFirst().dropLast())
            return parameters[name].map(encodePathSegment) ?? String(segment)
        }.joined(separator: "/")
    }

    /// One path segment: unreserved characters stay, everything else (including `/`, `?`, `#`, `%`) is
    /// escaped; `.` and `..` are escaped too so no client or proxy treats them as dot-segments.
    static func encodePathSegment(_ value: String) -> String {
        if value == "." || value == ".." { return value.replacingOccurrences(of: ".", with: "%2E") }
        return percentEncode(value)
    }

    /// RFC 3986 percent-encoding keeping only `A–Z a–z 0–9 - . _ ~`.
    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
