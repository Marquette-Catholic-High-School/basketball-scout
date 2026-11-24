#if os(macOS)
import Foundation

/// Remembers the stream link of a game this Mac captures, so the capture can be resumed after the app was
/// quit. The link can carry a stream key or a password: it is kept in the Keychain only (never in the
/// settings, a file or a log), under the server and the game id, and removed when the capture ends.
nonisolated struct LiveLinkStore: Sendable {
    /// The Keychain service of the stream links (the server passwords have their own).
    static let service = "org.marquettecatholic.BasketballScout.live-stream"

    let keychain: any KeychainStore

    /// The app's store (the real Keychain).
    static let standard = LiveLinkStore(keychain: SecurityKeychainStore(service: service))

    /// The link remembered for `gameID`, when there is one that still reads as a stream link.
    func link(gameID: String, server: ServerAddress) -> LiveStreamLink? {
        guard let stored = try? keychain.password(for: account(gameID, server)) else { return nil }
        return try? LiveStreamLink(userInput: stored)
    }

    /// Remembers `link` for `gameID`. Not being able to is not an error for the capture: it only cannot be
    /// resumed without pasting the link again.
    func save(_ link: LiveStreamLink, gameID: String, server: ServerAddress) {
        try? keychain.setPassword(link.value, for: account(gameID, server))
    }

    func remove(gameID: String, server: ServerAddress) {
        try? keychain.removePassword(for: account(gameID, server))
    }

    private func account(_ gameID: String, _ server: ServerAddress) -> KeychainAccount {
        KeychainAccount(address: server, username: gameID)
    }
}
#endif
