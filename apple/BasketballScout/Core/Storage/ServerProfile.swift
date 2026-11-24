import Foundation

/// A server the app signs in to: its address, the username and what the coach agreed to. The password is
/// not here; it is in the Keychain under `keychainAccount` (02 §10 rule 8).
nonisolated struct ServerProfile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var address: ServerAddress
    /// The shared login's username (default `coach`, case-sensitive).
    var username: String
    /// The coach accepted, for this address, that the password crosses the network unencrypted
    /// (plain http; asked once per server, 02 §11 step 3, DESIGN §4).
    var acceptedPlainHTTPWarning: Bool
    /// False when the server has sign-in switched off (`auth_enabled: false`): no password is stored.
    var signInRequired: Bool
    /// The server version at the last successful sign-in (09 R9).
    var serverVersion: String?
    var lastSignedInAt: Date?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case address
        case username
        case acceptedPlainHTTPWarning = "accepted_plain_http_warning"
        case signInRequired = "sign_in_required"
        case serverVersion = "server_version"
        case lastSignedInAt = "last_signed_in_at"
    }

    init(
        id: UUID = UUID(),
        address: ServerAddress,
        username: String,
        acceptedPlainHTTPWarning: Bool = false,
        signInRequired: Bool = true,
        serverVersion: String? = nil,
        lastSignedInAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.username = username
        self.acceptedPlainHTTPWarning = acceptedPlainHTTPWarning
        self.signInRequired = signInRequired
        self.serverVersion = serverVersion
        self.lastSignedInAt = lastSignedInAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        address = try container.decode(ServerAddress.self, forKey: .address)
        username = try container.decode(String.self, forKey: .username)
        acceptedPlainHTTPWarning = try container.decodeIfPresent(Bool.self, forKey: .acceptedPlainHTTPWarning) ?? false
        signInRequired = try container.decodeIfPresent(Bool.self, forKey: .signInRequired) ?? true
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        lastSignedInAt = try container.decodeIfPresent(Date.self, forKey: .lastSignedInAt)
    }

    /// Where the password is kept.
    var keychainAccount: KeychainAccount { KeychainAccount(address: address, username: username) }

    /// The password would go out over plain http to another machine and the coach has not agreed yet.
    var needsPlainHTTPWarning: Bool { address.needsPlainHTTPWarning && !acceptedPlainHTTPWarning }
}
