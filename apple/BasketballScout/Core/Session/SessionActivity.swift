import Foundation

/// Something that sends requests on its own (a poller, a job follower) and must stop at once when the
/// lockout gate trips or the coach signs out (09 R6: "stop ALL requests, pollers and uploads").
///
/// Register with `ServerSession.register(_:)`; the session keeps a weak reference.
protocol SessionActivity: AnyObject {
    /// Cancel every task that sends requests. Called on the main actor.
    func sessionDidStop()
}

/// A weak reference to a registered activity.
struct WeakSessionActivity {
    weak var object: (any SessionActivity)?
}
