import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plain-text copy to the system pasteboard (technical details, ids). Exports that need both plain
/// text and HTML (09 R45) write their own pasteboard item.
enum ScoutPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
