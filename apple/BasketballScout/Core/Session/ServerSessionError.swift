import Foundation

/// Problems of the app's own session (not answers from the server).
nonisolated enum ServerSessionError: Error, Hashable, Sendable {
    /// Something tried to reach the server while signed out (or after the lockout gate stopped everything).
    case notSignedIn
}

nonisolated extension ServerSessionError: PresentableError {
    var title: String {
        switch self {
        case .notSignedIn: "Not signed in"
        }
    }

    var message: String {
        switch self {
        case .notSignedIn: "Sign in to your Basketball Scout server first."
        }
    }
}
