import Foundation

/// The app's one URLSession setup (DESIGN §4; 02 §5, §10; 09 R5, R7, R44).
///
/// - Credentials: `urlCredentialStorage = nil`, so URLSession never answers a 401 by itself with a stored
///   password (each automatic retry with a wrong password would count toward the school-wide lockout).
///   The client sets `Authorization` on every request instead, and the server's challenge (`WWW-Authenticate`
///   on every 401) is cancelled (`ScoutAuthChallenge`): any other answer makes CFNetwork send the request a
///   second time. Each task's delegate (`ScoutTaskDelegate`) turns that cancellation back into the 401.
/// - Cookies: the `scout_device` cookie protects this device from lockouts caused by others on the same
///   network. It must be kept: `HTTPCookieStorage.shared` (persisted, also read by AVURLAsset, 09 B9),
///   accept policy `.always`, cookies sent automatically. Never set a `Cookie` header by hand.
/// - Privacy: no URL cache (rosters, analyses and reports name minors), every request bypasses caches.
/// - Redirects are never followed (`ScoutSessionDelegate`): a 301 would turn a POST into a GET, and a
///   redirect must not carry the password to another origin. The connection checker follows them itself.
nonisolated enum ScoutHTTP {
    /// The session every `APIClient` uses unless a test passes its own.
    static let shared: URLSession = makeSession(configuration: makeConfiguration())

    /// The §4 configuration. Tests add `protocolClasses` to a copy and pass it to `makeSession`.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        // Idle timeout between packets; requests set their own (APIClient.Timeout).
        configuration.timeoutIntervalForRequest = APIClient.Timeout.standard
        // Fail at once when offline instead of waiting silently: the UI explains what is wrong.
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// A session with `configuration` and the app's delegate (default challenge handling, no redirects).
    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: ScoutSessionDelegate(), delegateQueue: nil)
    }

    /// Deletes the cookies the app would send to `address` (the `scout_device` cookie): on sign-out or when
    /// the server changes (02 §5, 09 R7). Returns how many were removed.
    @discardableResult
    static func removeCookies(for address: ServerAddress, in storage: HTTPCookieStorage = .shared) -> Int {
        let cookies = storage.cookies(for: address.origin) ?? []
        for cookie in cookies { storage.deleteCookie(cookie) }
        return cookies.count
    }
}
