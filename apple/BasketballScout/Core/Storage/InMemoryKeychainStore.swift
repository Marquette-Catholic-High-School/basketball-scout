import Foundation
import Synchronization

/// A Keychain that lives in memory: for unit tests and previews (DESIGN §7: tests never touch the user's
/// Keychain). Thread-safe. `failNextCall(with:)` makes the next call throw, to test error paths.
nonisolated final class InMemoryKeychainStore: KeychainStore {
    private struct State {
        var items: [KeychainAccount: String] = [:]
        var nextError: KeychainError?
    }

    private let state: Mutex<State>

    init(items: [KeychainAccount: String] = [:]) {
        state = Mutex(State(items: items))
    }

    /// Everything stored, for assertions.
    var items: [KeychainAccount: String] {
        state.withLock { $0.items }
    }

    /// The next call (any operation) throws `error`.
    func failNextCall(with error: KeychainError) {
        state.withLock { $0.nextError = error }
    }

    func password(for account: KeychainAccount) throws(KeychainError) -> String? {
        try access { $0.items[account] }
    }

    func setPassword(_ password: String, for account: KeychainAccount) throws(KeychainError) {
        try access { $0.items[account] = password }
    }

    func removePassword(for account: KeychainAccount) throws(KeychainError) {
        try access { $0.items[account] = nil }
    }

    func removeAllPasswords() throws(KeychainError) {
        try access { $0.items.removeAll() }
    }

    /// Runs `body` under the lock unless a failure is pending.
    private func access<T: Sendable>(_ body: (inout State) -> T) throws(KeychainError) -> T {
        let result: Result<T, KeychainError> = state.withLock { state in
            if let error = state.nextError {
                state.nextError = nil
                return .failure(error)
            }
            return .success(body(&state))
        }
        return try result.get()
    }
}
