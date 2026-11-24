#if os(macOS)
import Foundation

/// Keeps the Mac working while a live game is captured. `SystemLiveKeepAwake` is the real one.
protocol LiveKeepAwake: AnyObject {
    /// A capture started.
    func begin()
    /// That capture is over. Calls balance `begin()`.
    func end()
}

/// While any capture runs, an activity keeps the Mac from idle sleep and the app out of App Nap, so ffmpeg
/// keeps being read and the parts keep being sent with the lid open and nobody at the keyboard.
final class SystemLiveKeepAwake: LiveKeepAwake {
    private var count = 0
    private var activity: (any NSObjectProtocol)?

    func begin() {
        count += 1
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Capturing a live game")
    }

    func end() {
        count = max(0, count - 1)
        guard count == 0, let current = activity else { return }
        ProcessInfo.processInfo.endActivity(current)
        activity = nil
    }
}
#endif
