import Foundation

/// The delegate of every app session (`ScoutHTTP.makeSession`).
///
/// - Authentication challenges: `ScoutAuthChallenge` decides (the server's HTTP authentication is
///   cancelled so CFNetwork never sends a request a second time; server trust and client certificates get
///   the default handling, the system trust store only, 09 R4). The per-task delegates answer first and
///   keep the 401 for their callers (`ScoutTaskDelegate`, `VideoRangeLoad`); this is the fallback for a task
///   without one, which then sees the 401 as a cancellation. There is deliberately no session-level
///   challenge method: connection-level challenges (NTLM, Negotiate, server trust) then come to the task
///   level too, where the task is known.
/// - Redirects are refused, so the redirect response itself is returned. The server never redirects an
///   API call it accepts; a redirect means the address changed (certbot's http → https, 02 §1.1), which
///   only the connection checker may adopt, and following one could send the password elsewhere or turn
///   a POST into a GET.
nonisolated final class ScoutSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(ScoutAuthChallenge.disposition(for: challenge), nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
