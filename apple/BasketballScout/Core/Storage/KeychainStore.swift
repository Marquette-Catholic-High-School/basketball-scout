import Foundation

/// Where the server password is kept (02 §10 rule 8: Keychain only, never in UserDefaults, logs or URLs).
///
/// The app uses `SecurityKeychainStore`; tests and previews use `InMemoryKeychainStore`, so no test ever
/// touches the user's Keychain (DESIGN §7). Calls are synchronous and can be made from any actor.
nonisolated protocol KeychainStore: Sendable {
    /// The stored password, or nil when there is none.
    func password(for account: KeychainAccount) throws(KeychainError) -> String?
    /// Stores or replaces the password.
    func setPassword(_ password: String, for account: KeychainAccount) throws(KeychainError)
    /// Removes the password; removing a missing one is not an error.
    func removePassword(for account: KeychainAccount) throws(KeychainError)
    /// Removes every password this app stored (sign out of every server).
    func removeAllPasswords() throws(KeychainError)
}

/// One stored password: a generic-password item with service `org.marquettecatholic.BasketballScout.server`
/// and account `<origin>|<username>` (DESIGN §6 [B1]).
nonisolated struct KeychainAccount: Hashable, Sendable, CustomStringConvertible {
    /// The Keychain service of every server password.
    static let service = "org.marquettecatholic.BasketballScout.server"

    /// `scheme://host[:port]`.
    let origin: String
    let username: String

    init(address: ServerAddress, username: String) {
        self.origin = address.originString
        self.username = username
    }

    /// The item's `kSecAttrAccount`: `<origin>|<username>`.
    var account: String { "\(origin)|\(username)" }

    var description: String { account }
}
