import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Prints a scouting report natively from its HTML rendering (03 §10.10; 09 R45): the web's "Print" prints
/// only the report. iOS: the system print sheet (its preview can also share or save a PDF); macOS: the
/// print panel (with "Save as PDF").
enum ReportPrinter {
    /// Printing works here (always on the Mac; iOS reports whether a printing service exists).
    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        UIPrintInteractionController.isPrintingAvailable
        #endif
    }

    /// Shows the print UI for `html`. Returns an error to show when printing cannot start.
    @discardableResult
    static func print(html: String, jobName: String) -> (any PresentableError)? {
        #if os(macOS)
        guard let textView = makeTextView(html: html) else { return renderError }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        layOut(textView, width: max(200, printInfo.paperSize.width - 2 * margin))
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        return nil
        #else
        guard UIPrintInteractionController.isPrintingAvailable else {
            return DisplayError(title: ReportTexts.print, message: ReportTexts.printUnavailable)
        }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        controller.printInfo = info
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        controller.printFormatter = formatter
        controller.present(animated: true, completionHandler: nil)
        return nil
        #endif
    }

    /// Half an inch.
    private static let margin: CGFloat = 36

    private static var renderError: DisplayError {
        DisplayError(
            title: "Couldn't print the report",
            message: "The app could not lay out the scouting report for printing.",
            isRetryable: true)
    }

    #if os(macOS)
    /// The report laid out by AppKit's HTML importer in a light text view (printing is always light).
    static func makeTextView(html: String) -> NSTextView? {
        guard let attributed = NSAttributedString(
            html: Data(html.utf8),
            options: [.characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        else { return nil }
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.appearance = NSAppearance(named: .aqua)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    /// Sizes the text view to the page width and the full height of its text, so AppKit paginates it.
    static func layOut(_ textView: NSTextView, width: CGFloat) {
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        container.widthTracksTextView = true
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).height)
        textView.setFrameSize(NSSize(width: width, height: max(height, 100)))
    }
    #endif
}
