import Foundation

/// A successful check.
nonisolated struct ConnectionSuccess: Hashable, Sendable {
    /// The address to save. It can differ from the typed one: https after the server redirected there,
    /// or port 8000 found for an install without nginx (02 §11 step 1).
    let address: ServerAddress
    let health: HealthStatus
    /// False when the server has sign-in switched off (`auth_enabled: false`): there is no password to keep.
    let signInRequired: Bool

    /// The server works but something needs attention (`status == "degraded"`): show `health.notices`
    /// without blocking (02 §11 step 3).
    var isDegraded: Bool { health.status != .ok }

    /// The server runs the version this app was built against (02 §11 step 4); others usually work too.
    var isTestedServerVersion: Bool { health.version == ConnectionChecker.testedServerVersion }

    /// "Connected", or "Connected, but the server needs attention" (02 §11).
    var title: String { isDegraded ? "Connected, but the server needs attention" : "Connected" }

    var message: String {
        signInRequired ? "Signed in to \(address.displayString)." : "This server doesn't use a password."
    }
}
