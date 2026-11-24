import Foundation
import Network

/// Why a request got no HTTP answer, read from its `URLError`, with the coach-facing wording of the
/// 02 §11 connection checklist. Used by `APIError.transport` and by `ConnectionChecker`.
nonisolated enum NetworkProblem: Hashable, Sendable {
    /// -1003 `cannotFindHost`, -1006 `dnsLookupFailed`.
    case cannotFindHost
    /// -1004 `cannotConnectToHost`: nothing listens there (wrong port, server off).
    case cannotConnect
    /// -1001 `timedOut`.
    case timedOut
    /// -1009 `notConnectedToInternet` (also -1020 `dataNotAllowed`).
    case offline
    /// The Local Network permission is off: connections to the school network fail like "offline"
    /// (02 §12.4, 09 R2); the error's network path says "Local network prohibited".
    case localNetworkDenied
    /// -1005 `networkConnectionLost` (uvicorn closes idle keep-alive sockets after 5 s, 02 §12.10).
    case connectionLost
    /// -1022: App Transport Security refused plain http to this host.
    case httpsRequired
    /// -1202 `serverCertificateUntrusted`, -1203 `serverCertificateHasUnknownRoot`.
    case certificateUntrusted
    /// -1201 `serverCertificateHasBadDate`.
    case certificateExpired
    /// -1204 `serverCertificateNotYetValid`.
    case certificateNotYetValid
    /// -1200 `secureConnectionFailed`.
    case secureConnectionFailed
    /// -1206 `clientCertificateRequired`, -1205 `clientCertificateRejected`.
    case clientCertificateRequired
    /// Any other URLError code (raw value).
    case other(Int)

    init(_ error: URLError) {
        if Self.isLocalNetworkDenied(error) {
            self = .localNetworkDenied
            return
        }
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: self = .cannotFindHost
        case .cannotConnectToHost: self = .cannotConnect
        case .timedOut: self = .timedOut
        case .notConnectedToInternet, .dataNotAllowed: self = .offline
        case .networkConnectionLost: self = .connectionLost
        case .appTransportSecurityRequiresSecureConnection: self = .httpsRequired
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot: self = .certificateUntrusted
        case .serverCertificateHasBadDate: self = .certificateExpired
        case .serverCertificateNotYetValid: self = .certificateNotYetValid
        case .secureConnectionFailed: self = .secureConnectionFailed
        case .clientCertificateRequired, .clientCertificateRejected: self = .clientCertificateRequired
        default: self = .other(error.code.rawValue)
        }
    }

    /// The URLError code of an `other` problem.
    var otherCode: Int? {
        if case .other(let code) = self { return code }
        return nil
    }

    /// Whether trying again (unchanged) can help. TLS and ATS refusals need someone to change something.
    var isRetryable: Bool {
        switch self {
        case .httpsRequired, .certificateUntrusted, .certificateExpired, .certificateNotYetValid,
             .clientCertificateRequired:
            false
        default:
            true
        }
    }

    // MARK: - Wording (02 §11 "Messages")

    var title: String {
        switch self {
        case .cannotFindHost: "Can't find that server"
        case .cannotConnect: "Nothing answered"
        case .timedOut: "The server didn't answer"
        case .offline: "This device is offline"
        case .localNetworkDenied: "Local Network access is off"
        case .connectionLost: "The connection dropped"
        case .httpsRequired: "This address needs https"
        case .certificateUntrusted: "Certificate not trusted"
        case .certificateExpired: "Certificate expired"
        case .certificateNotYetValid: "Certificate not valid yet"
        case .secureConnectionFailed: "Couldn't make a secure connection"
        case .clientCertificateRequired: "This network needs a device certificate"
        case .other: "Can't reach the server"
        }
    }

    /// - Parameters:
    ///   - host: the server's host as the coach typed it.
    ///   - hostAndPort: `host:port`, port always shown.
    func message(host: String, hostAndPort: String) -> String {
        switch self {
        case .cannotFindHost: "No server called “\(host)” was found."
        case .cannotConnect: "No Basketball Scout server is answering at \(hostAndPort)."
        case .timedOut: "Nothing came back from \(host) in time."
        case .offline: "Connect to Wi-Fi or the school network."
        case .localNetworkDenied: "Basketball Scout isn't allowed to reach servers on this network."
        case .connectionLost: "The connection to \(host) was lost before the answer arrived."
        case .httpsRequired: "For safety the app only connects to \(host) over https."
        case .certificateUntrusted: "This device doesn't trust \(host)'s security certificate."
        case .certificateExpired: "\(host)'s certificate has expired, or this device's date and time are wrong."
        case .certificateNotYetValid: "\(host)'s certificate is not valid yet, or this device's date and time are wrong."
        case .secureConnectionFailed: "\(host) didn't complete an https connection."
        case .clientCertificateRequired: "\(host) asked for a certificate this device doesn't have."
        case .other: "The app could not reach the Basketball Scout server."
        }
    }

    /// - Parameter plainHTTPAllowed: the host may be reached over http (IP, single-label or `.local`).
    func hint(plainHTTPAllowed: Bool) -> String? {
        switch self {
        case .cannotFindHost:
            "Check the spelling. If your school uses Tailscale, open the Tailscale app and connect, then try again."
        case .cannotConnect:
            "Check the address and port (a server set up without nginx uses port 8000). It may be restarting or switched off."
        case .timedOut:
            "Make sure this device is on the school network (or VPN/Tailscale), then try again."
        case .offline:
            nil
        case .localNetworkDenied:
            Self.localNetworkSettingsHint
        case .connectionLost:
            "Try again."
        case .httpsRequired:
            "Use the https:// address, or ask IT to set up HTTPS (certbot, school certificate or Tailscale)."
        case .certificateUntrusted:
            "If your school uses its own certificate, install and trust its profile (iPhone/iPad: Settings > "
                + "General > About > Certificate Trust Settings; Mac: Keychain Access). If you typed an IP address "
                + "with https, use the server's name instead."
        case .certificateExpired:
            "Check the date and time; otherwise ask IT to renew the certificate."
        case .certificateNotYetValid:
            "Check this device's date and time."
        case .secureConnectionFailed:
            plainHTTPAllowed
                ? "If the server has no HTTPS yet, ask IT; the http:// address works but sends your password unencrypted."
                : "If the server has no HTTPS yet, ask IT to set it up (certbot, school certificate or Tailscale). "
                    + "On the school network you can also use the server's IP address."
        case .clientCertificateRequired:
            "Ask IT."
        case .other:
            "Check the network connection (or that the server is running) and try again."
        }
    }

    /// Where the Local Network switch is on this platform (02 §11 "offline" row).
    static var localNetworkSettingsHint: String {
        #if os(macOS)
        "Allow Local Network access for Basketball Scout in System Settings > Privacy & Security > Local Network, then try again."
        #else
        "Allow Local Network access for Basketball Scout in Settings > Privacy & Security > Local Network, then try again."
        #endif
    }

    // MARK: - Local Network permission

    /// The URL loading system reports a denied Local Network permission as a failed connection whose
    /// network path is unsatisfied with reason "local network denied" (shown as "Local network
    /// prohibited"). The path sits under `_NSURLErrorNWPathKey` in the error or an underlying error.
    static func isLocalNetworkDenied(_ error: URLError) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 5 {
            if let path = nsError.userInfo[pathKey] {
                if let networkPath = path as? nw_path_t,
                   nw_path_get_unsatisfied_reason(networkPath) == nw_path_unsatisfied_reason_local_network_denied {
                    return true
                }
                let text = String(describing: path).lowercased()
                if text.contains("local network prohibited") || text.contains("local network denied") {
                    return true
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private static let pathKey = "_NSURLErrorNWPathKey"
}
