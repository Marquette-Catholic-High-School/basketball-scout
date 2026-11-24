import Foundation
import Security
import Testing
@testable import BasketballScout

/// The Keychain contract (DESIGN §6 [B1]). Tests never touch the user's Keychain (DESIGN §7): the
/// Security-framework store is checked through the queries it builds.
nonisolated struct KeychainStoreTests {
    static let address = try! ServerAddress(userInput: "10.20.30.40:8000")

    @Test func accountNamesOriginAndUsername() throws {
        let account = KeychainAccount(address: Self.address, username: "coach")
        #expect(account.account == "http://10.20.30.40:8000|coach")
        #expect(account.description == "http://10.20.30.40:8000|coach")
        #expect(KeychainAccount.service == "org.marquettecatholic.BasketballScout.server")
        let other = KeychainAccount(address: try ServerAddress(userInput: "https://scout.myschool.org"), username: "Coach")
        #expect(other.account == "https://scout.myschool.org|Coach")
        #expect(account != other)
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryKeychainStore()
        let account = KeychainAccount(address: Self.address, username: "coach")
        #expect(try store.password(for: account) == nil)
        try store.setPassword("pässwörd:ü€ 1", for: account)
        #expect(try store.password(for: account) == "pässwörd:ü€ 1")
        try store.setPassword("new-password", for: account)
        #expect(try store.password(for: account) == "new-password")
        #expect(store.items.count == 1)

        let second = KeychainAccount(address: Self.address, username: "assistant")
        try store.setPassword("other", for: second)
        try store.removePassword(for: account)
        #expect(try store.password(for: account) == nil)
        try store.removePassword(for: account)  // removing a missing one is fine
        #expect(try store.password(for: second) == "other")
        try store.removeAllPasswords()
        #expect(store.items.isEmpty)
    }

    @Test func inMemoryStoreCanFail() throws {
        let store = InMemoryKeychainStore(items: [KeychainAccount(address: Self.address, username: "coach"): "secret"])
        let account = KeychainAccount(address: Self.address, username: "coach")
        store.failNextCall(with: .locked)
        #expect(throws: KeychainError.locked) { try store.password(for: account) }
        // Only the next call fails.
        #expect(try store.password(for: account) == "secret")
        store.failNextCall(with: .unexpectedStatus(errSecIO))
        #expect(throws: KeychainError.unexpectedStatus(errSecIO)) { try store.setPassword("x", for: account) }
        #expect(try store.password(for: account) == "secret")
    }

    @Test func storeIsUsableThroughTheProtocol() throws {
        let store: any KeychainStore = InMemoryKeychainStore()
        let account = KeychainAccount(address: Self.address, username: "coach")
        try store.setPassword("secret", for: account)
        #expect(try store.password(for: account) == "secret")
    }

    // MARK: Security framework queries

    @Test func itemQueriesMatchTheContract() throws {
        let account = KeychainAccount(address: Self.address, username: "coach")
        let query = SecurityKeychainStore.query(service: KeychainAccount.service, account: account.account, dataProtection: true)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "org.marquettecatholic.BasketballScout.server")
        #expect(query[kSecAttrAccount as String] as? String == "http://10.20.30.40:8000|coach")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecValueData as String] == nil)

        let attributes = SecurityKeychainStore.newItemAttributes(
            service: KeychainAccount.service, account: account, password: Data("secret".utf8), dataProtection: true)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecValueData as String] as? Data == Data("secret".utf8))
        #expect(attributes[kSecAttrLabel as String] as? String == "Basketball Scout (http://10.20.30.40:8000)")

        // The Mac's login keychain (no access group) gets no data-protection-only attributes.
        let legacy = SecurityKeychainStore.newItemAttributes(
            service: KeychainAccount.service, account: account, password: Data(), dataProtection: false)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecAttrAccessible as String] == nil)
        #expect(legacy[kSecAttrSynchronizable as String] == nil)

        // Removing everything matches the service only.
        let all = SecurityKeychainStore.query(service: KeychainAccount.service, account: nil, dataProtection: true)
        #expect(all[kSecAttrAccount as String] == nil)
        #expect(SecurityKeychainStore().service == KeychainAccount.service)
    }

    @Test func errorsArePresentable() {
        #expect(KeychainError(status: errSecInteractionNotAllowed) == .locked)
        #expect(KeychainError(status: errSecIO) == .unexpectedStatus(errSecIO))
        #expect(KeychainError.locked.title == "Unlock this device")
        #expect(KeychainError.locked.isRetryable)
        #expect(!KeychainError.unreadableItem.isRetryable)
        #expect(KeychainError.unexpectedStatus(-25300).detail == "Keychain status -25300")
    }
}
