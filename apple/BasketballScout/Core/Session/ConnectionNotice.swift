import Foundation

/// What a successful sign-in has to say before the coach starts (02 §11 "Success" rows; 09 R9, R43):
/// the server needs attention, runs in demo mode, has no password, or runs a version this app was not
/// built against. Shown once, after the sign-in screen is gone.
nonisolated struct ConnectionNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let success: ConnectionSuccess

    init(id: UUID = UUID(), success: ConnectionSuccess) {
        self.id = id
        self.success = success
    }

    /// Whether `success` has anything to say beyond "Signed in".
    static func isWorthShowing(_ success: ConnectionSuccess) -> Bool {
        success.isDegraded || success.health.isDemoMode || !success.signInRequired || !success.isTestedServerVersion
    }
}
