import Foundation
import Security

/// The real Keychain (Security framework): one generic-password item per server and username
/// (`KeychainAccount`), accessible after the first unlock on this device only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced, never restored to another device),
/// not synchronizable.
///
/// macOS uses the data protection keychain like iOS. A build signed without a team ("Sign to Run
/// Locally") has no keychain access group, so that keychain answers `errSecMissingEntitlement`; the store
/// then uses the login keychain instead, which has no accessibility classes.
nonisolated struct SecurityKeychainStore: KeychainStore {
    let service: String

    init(service: String = KeychainAccount.service) {
        self.service = service
    }

    func password(for account: KeychainAccount) throws(KeychainError) -> String? {
        var item: CFTypeRef?
        let status = Self.withFallback { dataProtection in
            var query = Self.query(service: service, account: account.account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw .unreadableItem
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setPassword(_ password: String, for account: KeychainAccount) throws(KeychainError) {
        let data = Data(password.utf8)
        let status = Self.withFallback { dataProtection in
            let query = Self.query(service: service, account: account.account, dataProtection: dataProtection)
            var changes: [String: Any] = [kSecValueData as String: data]
            if dataProtection {
                changes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            let attributes = Self.newItemAttributes(
                service: service, account: account, password: data, dataProtection: dataProtection)
            return SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func removePassword(for account: KeychainAccount) throws(KeychainError) {
        let status = Self.withFallback { dataProtection in
            SecItemDelete(Self.query(service: service, account: account.account, dataProtection: dataProtection) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func removeAllPasswords() throws(KeychainError) {
        // The login keychain may delete one match per call, so repeat until nothing is left.
        for _ in 0..<100 {
            let status = Self.withFallback { dataProtection in
                SecItemDelete(Self.query(service: service, account: nil, dataProtection: dataProtection) as CFDictionary)
            }
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    // MARK: - Queries (pure, tested)

    /// Matches this app's item(s): generic password, service, account (nil = all of the service).
    static func query(service: String, account: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }

    /// A new item: the query plus the password, a label for Keychain Access, and the accessibility class.
    static func newItemAttributes(
        service: String, account: KeychainAccount, password: Data, dataProtection: Bool
    ) -> [String: Any] {
        var attributes = query(service: service, account: account.account, dataProtection: dataProtection)
        attributes[kSecValueData as String] = password
        attributes[kSecAttrLabel as String] = "Basketball Scout (\(account.origin))"
        if dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attributes
    }

    /// Runs `operation` against the data protection keychain; on a Mac build without a keychain access
    /// group, against the login keychain.
    private static func withFallback(_ operation: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        let status = operation(true)
        #if os(macOS)
        if status == errSecMissingEntitlement { return operation(false) }
        #endif
        return status
    }
}
