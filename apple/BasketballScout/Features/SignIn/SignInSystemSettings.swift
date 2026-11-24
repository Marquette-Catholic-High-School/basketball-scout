import Foundation
#if os(iOS)
import UIKit
#endif

/// Where the Local Network switch lives on this platform (02 §12.4, 09 R2).
enum SignInSystemSettings {
    /// The button that opens it.
    static var openTitle: String {
        #if os(macOS)
        "Open System Settings"
        #else
        "Open Settings"
        #endif
    }

    /// The app's page in Settings (iOS) or Privacy & Security > Local Network (macOS).
    static var localNetworkURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}
