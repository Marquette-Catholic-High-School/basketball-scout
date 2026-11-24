#if os(macOS)
import AppKit

/// The Mac app's delegate, for the one thing the SwiftUI life cycle has no hook for: quitting in the middle
/// of a live capture (docs/LIVE.md). It asks first; when the coach quits anyway, ffmpeg is interrupted and
/// waited for so its last part is closed, and the parts not yet sent stay on this Mac for the next launch.
///
/// Closing the window does not stop a capture: the app stays open, and the capture belongs to the app.
final class ScoutAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's captures; set by `BasketballScoutApp` once its model exists.
    var liveCapture: LiveCaptureCenter?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let liveCapture, liveCapture.isCapturing, !AppEnvironment.isRunningTests else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = LiveText.quitQuestionTitle
        alert.informativeText = LiveText.quitQuestionMessage
        // The first button is the default (Return): keep capturing.
        alert.addButton(withTitle: LiveText.keepCapturing)
        alert.addButton(withTitle: LiveText.quitAnyway)
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await liveCapture.suspendAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The last chance (a log-out that did not wait, for example): ffmpeg is told to finish; it is its own
    /// process and closes its last part even after the app is gone.
    func applicationWillTerminate(_ notification: Notification) {
        liveCapture?.interruptAll()
    }
}
#endif
