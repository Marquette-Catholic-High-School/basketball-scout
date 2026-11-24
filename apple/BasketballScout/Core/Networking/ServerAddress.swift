import Foundation

/// Where a Basketball Scout server lives: an origin `scheme://host[:port]` and nothing else (02 §1).
/// Every JSON route is `origin + "/api/..."`; there is no path prefix and no trailing slash.
///
/// `init(userInput:)` is 02 §11 step 0 (no network):
/// - Trims. Only `http://`, `https://` or no scheme. A pasted path, query or fragment, and a
///   `user:password@` part, are refused with an error that says what to remove (the app keeps the origin
///   only, and credentials never go in a URL: 02 §10 rule 8).
/// - No scheme typed: `*.ts.net` → https; an IP address, a single-label name (`scout`) or a `.local`
///   name → http (what install.sh prints for LAN installs); port 443 or any other dotted name → https.
/// - The host is lower-cased without a trailing dot; IPv6 literals keep their brackets in the origin;
///   the default port (80 for http, 443 for https) is dropped, any other port kept.
///
/// http policy (DESIGN §4; 09 R1, B10): ATS only has `NSAllowsLocalNetworking`, which covers IP literals,
/// unqualified names and `.local` names. `http://` to any other (dotted) name is refused
/// (`ServerAddressError.httpsRequired`). Plain http is used only after the coach accepts the
/// "password is sent unencrypted" warning (`needsPlainHTTPWarning`).
nonisolated struct ServerAddress: Hashable, Sendable, CustomStringConvertible {
    nonisolated enum Scheme: String, Hashable, Sendable, CaseIterable {
        case http
        case https

        var defaultPort: Int {
            switch self {
            case .http: 80
            case .https: 443
            }
        }
    }

    /// What kind of host the address names; it decides whether plain http is possible.
    nonisolated enum HostKind: Hashable, Sendable {
        case ipv4
        case ipv6
        /// A single label such as `scout` or `localhost`.
        case unqualified
        /// A multicast-DNS name ending in `.local`.
        case local
        /// Any other dotted name (`scout.myschool.org`): https only.
        case dotted
    }

    let scheme: Scheme
    /// Lower-case host; an IPv6 literal without its brackets (`fe80::1`).
    let host: String
    /// The port when it is not the scheme's default; nil means 80 (http) or 443 (https).
    let port: Int?
    let hostKind: HostKind
    /// `scheme://host[:port]`, no path and no trailing slash.
    let origin: URL

    /// Parses what the coach typed (02 §11 step 0). Throws an error that says what to fix.
    init(userInput: String) throws(ServerAddressError) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        guard !text.contains(where: \.isWhitespace) else { throw .unparsable }

        // A scheme counts only with "://": "scout:8000" is a host and a port, not the scheme "scout".
        var typedScheme: Scheme?
        var remainder = Substring(text)
        if let separator = text.range(of: "://") {
            let name = text[..<separator.lowerBound].lowercased()
            guard let scheme = Scheme(rawValue: name) else {
                throw name.isEmpty ? .unparsable : .unsupportedScheme(name)
            }
            typedScheme = scheme
            remainder = text[separator.upperBound...]
        }
        guard !remainder.isEmpty, let components = URLComponents(string: "http://" + remainder) else {
            throw .unparsable
        }
        if components.user != nil || components.password != nil { throw .containsCredentials }
        guard let rawHost = components.percentEncodedHost, !rawHost.isEmpty else { throw .unparsable }
        let (host, kind) = try Self.parseHost(rawHost)
        if let port = components.port, !(1...65_535).contains(port) { throw .invalidPort(String(port)) }

        let scheme = typedScheme ?? Self.assumedScheme(host: host, kind: kind, port: components.port)
        let address = try ServerAddress(validatedScheme: scheme, host: host, kind: kind, port: components.port)

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            throw .containsPath(path: path.removingPercentEncoding ?? path, suggestion: address.originString)
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            throw .containsQuery(suggestion: address.originString)
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            throw .containsQuery(suggestion: address.originString)
        }
        self = address
    }

    /// An address from its parts (the connection checker uses it to follow a redirect or try port 8000).
    /// `host` is given without brackets. Applies the same checks and http policy as `init(userInput:)`.
    init(scheme: Scheme, host: String, port: Int? = nil) throws(ServerAddressError) {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let (parsedHost, kind) = try Self.parseHost(bracketed)
        if let port, !(1...65_535).contains(port) { throw .invalidPort(String(port)) }
        try self.init(validatedScheme: scheme, host: parsedHost, kind: kind, port: port)
    }

    private init(validatedScheme scheme: Scheme, host: String, kind: HostKind, port: Int?) throws(ServerAddressError) {
        // DESIGN §4: plain http only to hosts ATS's NSAllowsLocalNetworking covers.
        if scheme == .http, kind == .dotted { throw .httpsRequired(host: host) }
        let normalizedPort = port == scheme.defaultPort ? nil : port
        let hostForURL = kind == .ipv6 ? "[\(host)]" : host
        let originString = "\(scheme.rawValue)://\(hostForURL)" + (normalizedPort.map { ":\($0)" } ?? "")
        guard let origin = URL(string: originString) else { throw .unparsable }
        self.scheme = scheme
        self.host = host
        self.port = normalizedPort
        self.hostKind = kind
        self.origin = origin
    }

    // MARK: - Facts about the address

    var isHTTPS: Bool { scheme == .https }

    /// An IP literal, a single-label name or a `.local` name: the hosts ATS lets the app reach over
    /// plain http (`NSAllowsLocalNetworking`, 09 B10).
    var isLocalNetworkHost: Bool { hostKind != .dotted }

    /// Plain http is possible for this host (after the warning). Dotted names need https.
    var allowsPlainHTTP: Bool { isLocalNetworkHost }

    /// `localhost`, `127.x.x.x` or `::1`: this device itself.
    var isLoopback: Bool {
        switch hostKind {
        case .ipv4: host.hasPrefix("127.")
        case .ipv6: host == "::1"
        case .unqualified: host == "localhost"
        case .local, .dotted: false
        }
    }

    /// The password would cross the network unencrypted: warn once before sending it (02 §11 step 3).
    var needsPlainHTTPWarning: Bool { scheme == .http && !isLoopback }

    /// The port in use, default or not.
    var effectivePort: Int { port ?? scheme.defaultPort }

    /// The host as written in a URL (IPv6 in brackets).
    var hostForURL: String { hostKind == .ipv6 ? "[\(host)]" : host }

    /// `host:port` with the port always shown, for messages ("No Basketball Scout server is answering at
    /// 10.20.30.40:8000.").
    var hostAndPort: String { "\(hostForURL):\(effectivePort)" }

    /// `scheme://host[:port]`.
    var originString: String { origin.absoluteString }

    /// What the app shows for this server (the full origin, so http and https are told apart).
    var displayString: String { originString }

    var description: String { originString }

    /// Whether `url` points at this server (same scheme, host and port). The client only puts the
    /// password on requests to its own server.
    func isSameOrigin(as url: URL) -> Bool {
        guard let schemeName = url.scheme?.lowercased(), let urlScheme = Scheme(rawValue: schemeName),
              let urlHost = url.host(percentEncoded: true) else { return false }
        var plainHost = urlHost.lowercased()
        if plainHost.hasPrefix("["), plainHost.hasSuffix("]") { plainHost = String(plainHost.dropFirst().dropLast()) }
        if plainHost.hasSuffix(".") { plainHost.removeLast() }
        return urlScheme == scheme && plainHost == host && (url.port ?? urlScheme.defaultPort) == effectivePort
    }

    /// The same host with another scheme and port (checked against the http policy).
    func with(scheme: Scheme, port: Int?) throws(ServerAddressError) -> ServerAddress {
        try ServerAddress(validatedScheme: scheme, host: host, kind: hostKind, port: port)
    }

    // MARK: - Parsing helpers

    /// 02 §11: `*.ts.net` → https; IP literal, single label or `.local` → http; port 443 or any other
    /// dotted name → https (http to a dotted name is not possible under ATS, so https even when an
    /// explicit non-443 port is typed: the connection check then explains a TLS failure).
    private static func assumedScheme(host: String, kind: HostKind, port: Int?) -> Scheme {
        if port == 443 || host.hasSuffix(".ts.net") { return .https }
        return kind == .dotted ? .https : .http
    }

    /// Lower-cases and classifies a host as URLComponents gives it (IPv6 in brackets).
    static func parseHost(_ raw: String) throws(ServerAddressError) -> (host: String, kind: HostKind) {
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else { throw .unparsable }
            let inner = String(raw.dropFirst().dropLast()).lowercased()
            // Zone ids (fe80::1%25en0, which inet_pton accepts) are not supported: plain installs are IPv4
            // only anyway (02 §1.1).
            guard !inner.contains("%"), isIPv6(inner) else { throw .unparsable }
            return (inner, .ipv6)
        }
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { throw .unparsable }
        if isIPv4(host) { return (host, .ipv4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let labelsAreValid = labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
        }
        guard labelsAreValid else { throw .unparsable }
        // "10.0.0" is neither an IPv4 address nor a name.
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { throw .unparsable }
        if labels.count == 1 { return (host, .unqualified) }
        if host.hasSuffix(".local") { return (host, .local) }
        return (host, .dotted)
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")

    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}

/// Stored as its origin string (`ServerProfile`); decoding re-applies the checks and the http policy.
nonisolated extension ServerAddress: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            self = try ServerAddress(userInput: text)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a usable server address: \(error.title)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(originString)
    }
}
