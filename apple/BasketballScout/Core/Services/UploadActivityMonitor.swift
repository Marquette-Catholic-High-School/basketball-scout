import Foundation

/// What the upload manager needs from the app's life cycle (09 R15): keep the device awake and ask for
/// background time while uploads run, and say when that time runs out and when the app is active again.
/// `SystemUploadActivity` is the real one; tests use a fake.
@MainActor
protocol UploadActivityMonitor: AnyObject {
    /// Called (main actor) shortly before the system suspends the app: stop uploads cleanly.
    var onBackgroundTimeExpiring: (() -> Void)? { get set }
    /// Called (main actor) when the app is active again: continue uploads stopped for the background.
    var onBecameActive: (() -> Void)? { get set }
    /// Whether any upload is running now.
    func uploadsDidChange(running: Bool)
}
