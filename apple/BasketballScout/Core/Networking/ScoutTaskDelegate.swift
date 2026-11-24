import Foundation
import Synchronization

/// Called while a chunk's bytes leave the device: bytes sent so far and the chunk's total.
typealias UploadProgressHandler = @Sendable (_ bytesSent: Int64, _ totalBytes: Int64) -> Void

/// The server's answer to a request whose authentication challenge the app cancelled: the 401 with its
/// headers (`WWW-Authenticate` names the realm). URLSession does not hand over the body of such an answer.
nonisolated struct AuthenticationRejection: Hashable, Sendable {
    let status: Int
    let headers: HTTPHeaders

    /// The answer as the app's error: a 401 is `APIError.unauthorized(nil)` (the lockout gate, 09 R6).
    var apiError: APIError { APIError.from(status: status, headers: headers, body: Data()) }
}

/// How the app answers authentication challenges (09 R4–R6).
///
/// - The server's own challenge (HTTP Basic: `WWW-Authenticate: Basic realm="Basketball Scout"` comes with
///   every 401; also Digest, NTLM, Negotiate and the HTTP default) is **cancelled**. After
///   `.performDefaultHandling`, `.rejectProtectionSpace` or `.useCredential(nil)` CFNetwork sends the same
///   request once more on a new connection, so each wrong password would count twice toward the server's
///   lockout (10 failures in 5 minutes per address) and each 401 while polling twice. Cancelling sends exactly
///   one request: the task fails with `URLError.cancelled` and the challenge's `failureResponse` is the 401,
///   which the task's delegate keeps so the caller can report it (`ScoutTaskDelegate`, `VideoRangeLoad`).
///   Nothing is lost: the app sets its own `Authorization` header on every request.
/// - Server trust and client certificates keep the default handling (the system trust store only, no
///   pinning, no bypass), and so does a proxy's challenge (it does not count toward the server's lockout).
nonisolated enum ScoutAuthChallenge {
    /// The HTTP authentication schemes a server can ask for.
    static let httpAuthenticationMethods: Set<String> = [
        NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault,
    ]

    /// The challenge asks for the server's username and password (not a proxy's, not a certificate).
    static func isServerAuthentication(_ challenge: URLAuthenticationChallenge) -> Bool {
        let space = challenge.protectionSpace
        return !space.isProxy() && httpAuthenticationMethods.contains(space.authenticationMethod)
    }

    /// `.cancelAuthenticationChallenge` for the server's HTTP authentication, else `.performDefaultHandling`.
    static func disposition(for challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        isServerAuthentication(challenge) ? .cancelAuthenticationChallenge : .performDefaultHandling
    }

    /// What the server answered: the challenge's failure response (the 401 and its headers), or a bare 401
    /// when the challenge carries none.
    static func rejection(from challenge: URLAuthenticationChallenge) -> AuthenticationRejection {
        guard let response = challenge.failureResponse as? HTTPURLResponse else {
            return AuthenticationRejection(status: 401, headers: HTTPHeaders())
        }
        return AuthenticationRejection(status: response.statusCode, headers: HTTPHeaders(response))
    }
}

/// The per-task delegate of every request `APIClient` and `ConnectionChecker` send (one per task, passed to
/// `data(for:delegate:)`, `upload(for:from:delegate:)`, `download(for:delegate:)`):
/// - answers authentication challenges by `ScoutAuthChallenge` and keeps the server's 401 when it cancelled
///   one, so `apiError(for:url:)` turns the task's cancellation back into that 401;
/// - reports a chunk PUT's progress (the upload engine's speed and stall watchdog).
/// Redirects still go to the session's `ScoutSessionDelegate` (refused).
nonisolated final class ScoutTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let progress: UploadProgressHandler?
    private let state = Mutex<AuthenticationRejection?>(nil)

    /// - Parameter progress: called as a request body is sent (chunk uploads).
    init(progress: UploadProgressHandler? = nil) {
        self.progress = progress
    }

    /// The server's answer when this delegate cancelled the task's authentication challenge.
    var rejection: AuthenticationRejection? { state.withLock { $0 } }

    /// The error a task of this delegate threw, as its caller sees it: the server's 401
    /// (`APIError.unauthorized`) when the task failed because this delegate cancelled its challenge; else the
    /// transport error, or `.cancelled` for a cancellation of the caller's own.
    func apiError(for error: any Error, url: URL?) -> APIError {
        let failure = APIError.from(transportError: error, url: url)
        guard failure.isCancellation, let rejection else { return failure }
        return rejection.apiError
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let disposition = ScoutAuthChallenge.disposition(for: challenge)
        if disposition == .cancelAuthenticationChallenge {
            let rejection = ScoutAuthChallenge.rejection(from: challenge)
            state.withLock { $0 = rejection }
        }
        completionHandler(disposition, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }
}
