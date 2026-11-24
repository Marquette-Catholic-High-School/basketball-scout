import Foundation

/// The shared Basketball Scout login (02 §3.1): one username (default `coach`, case-sensitive) and the
/// password, sent as HTTP Basic on every request except `GET /api/health/live`.
///
/// The password never appears in `description`, `debugDescription` or `dump` output. Keep the value in
/// memory only; the password itself lives in the Keychain (`KeychainStore`).
nonisolated struct ServerCredentials: Hashable, Sendable {
    var username: String
    var password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// No credentials: for a server with sign-in switched off (`auth_enabled: false`). Requests then carry
    /// no `Authorization` header, which never counts as a failed sign-in (02 §4).
    static let none = ServerCredentials(username: "", password: "")

    /// No username and no password: requests go without `Authorization`.
    var isAnonymous: Bool { username.isEmpty && password.isEmpty }

    /// The server splits `username:password` at the first colon, so a username cannot contain one
    /// (02 §3.1); sending it would only count as a wrong password.
    var hasValidUsername: Bool { !username.isEmpty && !username.contains(":") }

    /// `Basic ` + base64 of the UTF-8 bytes of `username:password`: standard alphabet with `=` padding,
    /// no Unicode normalisation and no trimming (02 §3.1). Nil for `none`.
    var authorizationHeaderValue: String? {
        guard !isAnonymous else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

nonisolated extension ServerCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        isAnonymous ? "ServerCredentials(none)" : "ServerCredentials(username: \(username), password: <hidden>)"
    }

    var debugDescription: String { description }

    /// Keeps the password out of `dump`, the debugger's summary and string interpolation of mirrors.
    var customMirror: Mirror {
        Mirror(self, children: ["username": username, "password": "<hidden>"], displayStyle: .struct)
    }
}
