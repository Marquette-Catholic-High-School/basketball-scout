import Foundation
#if os(iOS)
import UIKit
#endif

/// The app's `UploadActivityMonitor` (09 R15: v1 uploads in the foreground).
///
/// - iOS / iPadOS: while uploads run, the screen stays awake (`isIdleTimerDisabled`, restored to its
///   earlier value afterwards) and a background task asks for the grace period iOS gives an app that
///   leaves the screen. When that runs out, `onBackgroundTimeExpiring` stops the uploads cleanly (the
///   server keeps every finished chunk); `onBecameActive` continues them on return.
/// - macOS: an activity keeps the Mac from idle sleep and App Nap while uploads run.
final class SystemUploadActivity: UploadActivityMonitor {
    var onBackgroundTimeExpiring: (() -> Void)?
    var onBecameActive: (() -> Void)?

    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var savedIdleTimerDisabled: Bool?
    private var activeObserver: (any NSObjectProtocol)?
    #elseif os(macOS)
    private var activity: (any NSObjectProtocol)?
    #endif

    init() {
        #if os(iOS)
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBecameActive?() }
        }
        #endif
    }

    func uploadsDidChange(running: Bool) {
        #if os(iOS)
        let application = UIApplication.shared
        if running {
            if savedIdleTimerDisabled == nil {
                savedIdleTimerDisabled = application.isIdleTimerDisabled
                application.isIdleTimerDisabled = true
            }
            if backgroundTask == .invalid {
                backgroundTask = application.beginBackgroundTask(withName: "Film upload") { [weak self] in
                    MainActor.assumeIsolated { self?.backgroundTimeExpired() }
                }
            }
        } else {
            if let saved = savedIdleTimerDisabled {
                application.isIdleTimerDisabled = saved
                savedIdleTimerDisabled = nil
            }
            endBackgroundTask()
        }
        #elseif os(macOS)
        if running, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Uploading game film")
        } else if !running, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        #endif
    }

    #if os(iOS)
    private func backgroundTimeExpired() {
        onBackgroundTimeExpiring?()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}
