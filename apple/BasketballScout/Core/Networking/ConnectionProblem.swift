import Foundation

/// Why connecting or signing in stopped, with the wording of the 02 §11 "Messages" table.
nonisolated enum ConnectionProblem: Error, Hashable, Sendable {
    /// Step 0: the typed address cannot be used.
    case invalidAddress(ServerAddressError)
    /// No username typed.
    case missingUsername
    /// The username contains a colon, which HTTP Basic cannot carry (02 §3.1).
    case invalidUsername
    /// No password typed (sending an empty one would count as a wrong password).
    case missingPassword
    /// No HTTP answer (DNS, refused, timeout, offline, Local Network denied, TLS, ATS).
    case network(NetworkProblem, ServerAddress)
    /// Step 1: a web server (nginx's 404 page) answered, but not Basketball Scout — common with
    /// `--domain` installs reached by IP address (02 §1.1).
    case notBasketballScoutHere(ServerAddress)
    /// Step 1: 502/504 from the proxy: the server is up, the app on it is not.
    case appNotRunning(ServerAddress)
    /// Steps 1–2: something answered that is not Basketball Scout (captive portal, another site).
    case notBasketballScout(ServerAddress)
    /// Step 1: the address redirected to a different host. The coach must confirm it (02 §11).
    case redirectedElsewhere(from: ServerAddress, to: ServerAddress)
    /// 403 `HOST_NOT_ALLOWED` (02 §6.1); `serverMessage` is shown as the detail.
    case hostNotAllowed(host: String, serverMessage: String)
    /// 503 `AUTH_NOT_CONFIGURED` (02 §3.3); `serverMessage` is shown as the detail.
    case signInNotConfigured(serverMessage: String)
    /// 429 `AUTH_THROTTLED`: sign-in from this network is paused until `until` (count down; 02 §4).
    case throttled(retryAfter: TimeInterval, until: Date)
    /// Step 3: 401, the username or password is wrong.
    case wrongCredentials
    /// A 200 from `/api/health` that does not decode: an older or newer server.
    case unsupportedServerVersion(detail: String?)
    /// Any other error the server itself reported.
    case serverError(APIError)
    /// The check was cancelled.
    case cancelled
}

nonisolated extension ConnectionProblem: PresentableError {
    var title: String {
        switch self {
        case .invalidAddress(let error): error.title
        case .missingUsername: "Enter the username"
        case .invalidUsername: "Check the username"
        case .missingPassword: "Enter the password"
        case .network(let problem, _): problem.title
        case .notBasketballScoutHere: "Not Basketball Scout at this address"
        case .appNotRunning: "Basketball Scout isn't running"
        case .notBasketballScout: "Not a Basketball Scout server"
        case .redirectedElsewhere: "The server sent the app somewhere else"
        case .hostNotAllowed: "This server doesn't accept that name"
        case .signInNotConfigured: "Sign-in isn't set up on the server"
        case .throttled: "Too many wrong passwords"
        case .wrongCredentials: "Wrong username or password"
        case .unsupportedServerVersion: "Server version not supported"
        case .serverError(let error): error.title
        case .cancelled: "Cancelled"
        }
    }

    var message: String {
        switch self {
        case .invalidAddress(let error): error.message
        case .missingUsername: "The usual username is coach."
        case .invalidUsername: "A username can't contain a colon (:)."
        case .missingPassword: "Type the Basketball Scout password IT gave you."
        case .network(let problem, let address): problem.message(host: address.host, hostAndPort: address.hostAndPort)
        case .notBasketballScoutHere(let address): "A web server answered at \(address.host), but not Basketball Scout."
        case .appNotRunning:
            "The server is up, but the Basketball Scout app on it isn't answering (it may be restarting)."
        case .notBasketballScout(let address): "Something answered at \(address.displayString), but it isn't Basketball Scout."
        case .redirectedElsewhere(let from, let to): "\(from.host) sent the app on to \(to.displayString)."
        case .hostNotAllowed(let host, _): "The server doesn't answer to “\(host)”."
        case .signInNotConfigured: "The server has no coaches' password yet."
        case .throttled(let seconds, _):
            "Sign-in from this network is paused for about \(APIError.minutesText(seconds))."
        case .wrongCredentials: "The server didn't accept that username and password."
        case .unsupportedServerVersion: "This Basketball Scout server sent data this app can't read."
        case .serverError(let error): error.message
        case .cancelled: "The connection check was cancelled."
        }
    }

    var hint: String? {
        switch self {
        case .invalidAddress(let error): error.hint
        case .missingUsername, .invalidUsername: "Ask IT for the Basketball Scout username."
        case .missingPassword: nil
        case .network(let problem, let address): problem.hint(plainHTTPAllowed: address.allowsPlainHTTP)
        case .notBasketballScoutHere:
            "Try the server's name (for example scout.myschool.org) or ask IT for the exact address."
        case .appNotRunning: "Wait a minute and try again. IT: check basketball-scout-web."
        case .notBasketballScout: "Check the address. On guest Wi-Fi you may need to sign in to the network first."
        case .redirectedElsewhere(_, let to):
            "If \(to.host) is your Basketball Scout server, connect to it instead. On guest Wi-Fi you may need "
                + "to sign in to the network first."
        case .hostNotAllowed(let host, _):
            "Use the server's IP address, or ask IT to add “\(host)” to SCOUT_ALLOWED_HOSTS and restart the web app."
        case .signInNotConfigured: "Ask IT to set SCOUT_AUTH_PASSWORD in .env and restart the web app."
        case .throttled:
            "Wait, then try again with the right password (check it with IT). Devices that were already signed in keep working."
        case .wrongCredentials:
            "Both are case-sensitive; the usual username is coach. 10 wrong tries in 5 minutes lock this network out for 5 minutes."
        case .unsupportedServerVersion: "Ask IT to update the server (scripts/update.sh) or update the app."
        case .serverError(let error): error.hint
        case .cancelled: nil
        }
    }

    var detail: String? {
        switch self {
        case .network(let problem, _): problem.otherCode.map { "Network error \($0)" }
        case .hostNotAllowed(_, let serverMessage), .signInNotConfigured(let serverMessage): serverMessage
        case .unsupportedServerVersion(let detail): detail
        case .serverError(let error): error.detail
        default: nil
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network(let problem, _): problem.isRetryable
        case .appNotRunning, .cancelled: true
        case .serverError(let error): error.isRetryable
        default: false
        }
    }

    /// The address to offer instead ("Use …"): the redirect target, or the typed address without its
    /// path or query.
    var suggestedAddress: ServerAddress? {
        switch self {
        case .redirectedElsewhere(_, let to): to
        case .invalidAddress(let error): error.suggestedAddress.flatMap { try? ServerAddress(userInput: $0) }
        default: nil
        }
    }

    /// When "Sign in" may be pressed again (throttle countdown).
    var retryDate: Date? {
        if case .throttled(_, let until) = self { return until }
        return nil
    }

    /// From this many wrong passwords in a row, the sign-in screen also warns about the lockout (02 §11 step 3).
    static let lockoutWarningAfterWrongTries = 5

    /// The extra warning shown from the 5th wrong password in a row.
    static let lockoutWarning =
        "After 10 wrong tries in 5 minutes, sign-in from this network is paused for 5 minutes, also for other coaches here."
}
