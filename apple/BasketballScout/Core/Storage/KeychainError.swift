import Foundation
import Security

/// A Keychain operation failed.
nonisolated enum KeychainError: Error, Hashable, Sendable {
    /// The device is locked (or the item is not available yet after a restart): `errSecInteractionNotAllowed`.
    case locked
    /// The stored item is not a UTF-8 password.
    case unreadableItem
    /// Any other Security framework status.
    case unexpectedStatus(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed: self = .locked
        default: self = .unexpectedStatus(status)
        }
    }
}

nonisolated extension KeychainError: PresentableError {
    var title: String {
        switch self {
        case .locked: "Unlock this device"
        case .unreadableItem, .unexpectedStatus: "Couldn't use the saved password"
        }
    }

    var message: String {
        switch self {
        case .locked: "The saved password can be read once this device is unlocked."
        case .unreadableItem: "The password saved on this device could not be read."
        case .unexpectedStatus: "The app could not read or save the password in the Keychain."
        }
    }

    var hint: String? {
        switch self {
        case .locked: "Unlock the device, then try again."
        case .unreadableItem, .unexpectedStatus: "Sign in again to save the password once more."
        }
    }

    var detail: String? {
        if case .unexpectedStatus(let status) = self { return "Keychain status \(status)" }
        return nil
    }

    var isRetryable: Bool { self == .locked }
}
