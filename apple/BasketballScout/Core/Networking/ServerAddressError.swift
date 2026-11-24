import Foundation

/// Why a typed server address cannot be used (02 §11 step 0, DESIGN §4). Each case tells the coach what
/// to change; `containsPath` and `containsQuery` carry the address the app would use instead.
nonisolated enum ServerAddressError: Error, Hashable, Sendable {
    /// Nothing was typed.
    case empty
    /// Not an address at all (spaces, a missing host, a bad IPv6 literal, `%` escapes in the name…).
    case unparsable
    /// A scheme other than http or https (`ftp`, `file`…).
    case unsupportedScheme(String)
    /// `user:password@` in the address: credentials never go in a URL (02 §10 rule 8).
    case containsCredentials
    /// A path after the server (`/games/g_…`, a pasted page address). `suggestion` is the origin alone.
    case containsPath(path: String, suggestion: String)
    /// A `?query` or `#fragment` after the server. `suggestion` is the origin alone.
    case containsQuery(suggestion: String)
    /// A port outside 1…65535.
    case invalidPort(String)
    /// `http://` to a dotted DNS name: ATS (and the app's policy) allow plain http only on the school
    /// network by IP address, single-label or `.local` name (09 R1, B10).
    case httpsRequired(host: String)
}

nonisolated extension ServerAddressError: PresentableError {
    var title: String {
        switch self {
        case .empty: "Enter the server address"
        case .unparsable, .unsupportedScheme: "That doesn't look like a server address"
        case .containsCredentials: "Leave the sign-in details out of the address"
        case .containsPath, .containsQuery: "Type only the server address"
        case .invalidPort: "That port number isn't valid"
        case .httpsRequired: "This address needs https"
        }
    }

    var message: String {
        switch self {
        case .empty, .unparsable:
            "Type the address IT gave you, for example 10.20.30.40:8000 or scout.myschool.org."
        case .unsupportedScheme:
            "The address must start with http:// or https://, or with neither."
        case .containsCredentials:
            "Type the username and password in their own fields, not in the address."
        case .containsPath(let path, let suggestion):
            "Leave out “\(path)”. Use \(suggestion) instead."
        case .containsQuery(let suggestion):
            "Leave out everything after “?” or “#”. Use \(suggestion) instead."
        case .invalidPort:
            "A port is a number from 1 to 65535, for example 8000."
        case .httpsRequired(let host):
            "For safety the app only connects to \(host) over https."
        }
    }

    var hint: String? {
        switch self {
        case .httpsRequired:
            "On the school network, use the server's IP address instead (for example 10.20.30.40:8000), "
                + "or ask IT to set up HTTPS with Tailscale or certbot (see the server's docs/DEPLOYMENT.md)."
        case .unsupportedScheme:
            "For example 10.20.30.40:8000 or https://scout.myschool.org."
        default:
            nil
        }
    }

    /// The address to use instead, when the typed one only had extra parts.
    var suggestedAddress: String? {
        switch self {
        case .containsPath(_, let suggestion), .containsQuery(let suggestion): suggestion
        default: nil
        }
    }
}
