import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copies text to the system pasteboard as ONE item, with an HTML flavour when given (09 R45, 03 §6.2):
/// FastScout reads the HTML table when the paste block is pasted; Mail, Notes and Pages read the report's
/// HTML. Plain-text-only copies use `ScoutPasteboard`.
enum ReportPasteboard {
    /// The item's flavours: `public.utf8-plain-text`, then `public.html` when given.
    nonisolated static func representations(plainText: String, html: String?) -> [(type: UTType, value: String)] {
        var flavours: [(type: UTType, value: String)] = [(.utf8PlainText, plainText)]
        if let html { flavours.append((.html, html)) }
        return flavours
    }

    #if os(macOS)
    /// - Parameter pasteboard: the general pasteboard (tests pass a private one).
    static func copy(plainText: String, html: String?, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for flavour in representations(plainText: plainText, html: html) {
            item.setString(flavour.value, forType: NSPasteboard.PasteboardType(flavour.type.identifier))
        }
        pasteboard.writeObjects([item])
    }
    #else
    static func copy(plainText: String, html: String?) {
        var item: [String: Any] = [:]
        for flavour in representations(plainText: plainText, html: html) {
            item[flavour.type.identifier] = flavour.value
        }
        UIPasteboard.general.setItems([item])
    }
    #endif
}
