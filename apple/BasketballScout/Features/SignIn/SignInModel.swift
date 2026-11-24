import Foundation
import Observation

/// The sign-in form (02 §11): server address, username (default `coach`), password, and what the last
/// attempt found. Credentials are taken as typed: no trimming, no capitalisation (02 §10 rule 9).
///
/// The flow: parse the address (step 0) → `ServerSession.signIn` runs steps 1–3 → plain http asks once
/// for consent ("Your password will be sent unencrypted") → success switches the window to the games.
@Observable
final class SignInModel {
    var addressText: String
    var username: String
    var password: String
    /// A sign-in is running.
    private(set) var isWorking = false
    /// What the last attempt found (`ConnectionProblem`, a Keychain or server problem from the session).
    private(set) var problem: (any PresentableError)?
    /// Plain http to another machine: the warning is up for this address (02 §11 step 3, DESIGN §4).
    private(set) var plainHTTPConsentAddress: ServerAddress?

    @ObservationIgnored let session: ServerSession

    /// The username the server uses unless IT changed it (config.py:55).
    static let defaultUsername = "coach"

    /// Examples of what the installer prints (scripts/install.sh `app_url`), for the address field.
    static let addressExamples = "For example http://10.20.30.40:8000, http://scout.local or https://scout.myschool.org - the address the server's installer printed."

    init(session: ServerSession) {
        self.session = session
        addressText = session.profile?.address.displayString ?? ""
        username = session.profile?.username ?? Self.defaultUsername
        password = ""
        sync()
    }

    // MARK: - What the screen shows

    /// The end of a lockout: the session's, or the one the last attempt ran into.
    var lockedUntil: Date? {
        session.state.lockedUntil ?? (problem as? ConnectionProblem)?.retryDate
    }

    /// "Sign in" waits for the lockout to end.
    func isLocked(at date: Date) -> Bool {
        guard let lockedUntil else { return false }
        return lockedUntil > date
    }

    /// The saved password was refused (401): the message to show above the form.
    var passwordRejectedMessage: String? {
        if case .needsPassword(let message) = session.state { return message ?? ServerSession.passwordRejectedMessage }
        return nil
    }

    /// From the 5th wrong password in a row, warn about the lockout (02 §11 step 3).
    var showsLockoutWarning: Bool {
        session.consecutiveWrongPasswords >= ConnectionProblem.lockoutWarningAfterWrongTries
    }

    /// The problem to show as an error box (a lockout has its own notice).
    var shownProblem: (any PresentableError)? {
        if let connection = problem as? ConnectionProblem, case .throttled = connection { return nil }
        return problem
    }

    /// The address to offer instead ("Use …"): the redirect target or the address without its path.
    var suggestedAddress: ServerAddress? {
        (problem as? ConnectionProblem)?.suggestedAddress
    }

    /// The Local Network permission is off (02 §12.4, 09 R2): offer the system settings.
    var isLocalNetworkDenied: Bool {
        guard let connection = problem as? ConnectionProblem, case .network(let network, _) = connection else { return false }
        return network == .localNetworkDenied
    }

    /// Enough is typed to try.
    var canSubmit: Bool {
        !isWorking && !addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !username.isEmpty
    }

    // MARK: - Actions

    /// "Sign in".
    func signIn() async {
        guard canSubmit, !isLocked(at: Date()) else { return }
        let address: ServerAddress
        do {
            address = try ServerAddress(userInput: addressText)
        } catch {
            problem = ConnectionProblem.invalidAddress(error)
            return
        }
        await attempt(address: address, acceptPlainHTTP: false)
    }

    /// "Continue" in the plain-http warning.
    func continueOverPlainHTTP(to address: ServerAddress) async {
        plainHTTPConsentAddress = nil
        await attempt(address: address, acceptPlainHTTP: true)
    }

    /// "Cancel" in the plain-http warning: nothing was sent with the password.
    func cancelPlainHTTP() {
        plainHTTPConsentAddress = nil
    }

    /// "Use …": takes the suggested address.
    func useSuggestedAddress() {
        guard let suggestedAddress else { return }
        addressText = suggestedAddress.displayString
        problem = nil
    }

    /// Takes over what the session says after it changed (a check finished, the lockout gate tripped).
    func sync() {
        switch session.state {
        case .needsPassword:
            password = ""
            problem = nil
        case .locked:
            if password.isEmpty { password = session.savedPassword() ?? "" }
        case .signedOut:
            if let sessionProblem = session.problem {
                problem = sessionProblem
                if password.isEmpty { password = session.savedPassword() ?? "" }
            }
        case .checking, .signedIn:
            break
        }
        if addressText.isEmpty, let profile = session.profile {
            addressText = profile.address.displayString
            username = profile.username
        }
    }

    private func attempt(address: ServerAddress, acceptPlainHTTP: Bool) async {
        isWorking = true
        defer { isWorking = false }
        problem = nil
        let result = await session.signIn(
            address: address, username: username, password: password, acceptPlainHTTP: acceptPlainHTTP)
        switch result {
        case .connected:
            password = ""
        case .needsPlainHTTPConsent(let reachable):
            addressText = reachable.displayString
            plainHTTPConsentAddress = reachable
        case .failed(let failure):
            guard failure != .cancelled else { return }
            problem = failure
            if failure == .wrongCredentials { password = "" }
        }
    }
}
