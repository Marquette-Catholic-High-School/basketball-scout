import Foundation

/// Response headers with case-insensitive names (HTTP/1.1 header names are case-insensitive; uvicorn
/// sends them lower-case, nginx capitalised).
nonisolated struct HTTPHeaders: Hashable, Sendable {
    private var storage: [String: String]

    init(_ fields: [String: String] = [:]) {
        var storage: [String: String] = [:]
        for (name, value) in fields { storage[name.lowercased()] = value }
        self.storage = storage
    }

    init(_ response: HTTPURLResponse) {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            fields[name] = value as? String ?? String(describing: value)
        }
        self.init(fields)
    }

    subscript(name: String) -> String? {
        storage[name.lowercased()]
    }

    /// `Retry-After` (02 §3.3: whole seconds on a 429 `AUTH_THROTTLED`).
    var retryAfter: String? { self["Retry-After"] }
    var contentType: String? { self["Content-Type"] }
    var contentDisposition: String? { self["Content-Disposition"] }
    var location: String? { self["Location"] }
    var wwwAuthenticate: String? { self["WWW-Authenticate"] }

    /// The 401 challenge names the Basketball Scout realm: `Basic realm="Basketball Scout", charset="UTF-8"`
    /// (02 §3.3). Before sign-in this is the best fingerprint of the server (02 §12.12).
    var hasBasketballScoutRealm: Bool {
        guard let challenge = wwwAuthenticate?.lowercased() else { return false }
        return challenge.hasPrefix("basic") && challenge.contains("realm=\"basketball scout\"")
    }
}
