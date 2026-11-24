import Foundation

/// What `ConnectionChecker.check` found (02 §11).
nonisolated enum ConnectionCheckResult: Hashable, Sendable {
    /// Signed in, or the server has sign-in switched off.
    case connected(ConnectionSuccess)
    /// Steps 1–2 passed, the server wants a password, and the address is plain http to another machine:
    /// show `ConnectionChecker.PlainHTTPWarning` and, on Continue, check again with `acceptPlainHTTP: true`.
    /// No password was sent.
    case needsPlainHTTPConsent(ServerAddress)
    /// A step failed: show the problem.
    case failed(ConnectionProblem)

    var success: ConnectionSuccess? {
        if case .connected(let success) = self { return success }
        return nil
    }

    /// The server's health on success.
    var health: HealthStatus? { success?.health }

    var problem: ConnectionProblem? {
        if case .failed(let problem) = self { return problem }
        return nil
    }
}
