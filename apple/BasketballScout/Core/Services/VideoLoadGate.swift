import Foundation
import Synchronization

/// State shared by the resource loaders of one `VideoAssetFactory`: the first error that stops every
/// request (a 401 or 429 `AUTH_THROTTLED`; 09 R6), the last failure, and whether the factory was
/// invalidated. A loader checks it before it sends anything.
nonisolated final class VideoLoadGate: Sendable {
    private struct State {
        var stopError: APIError?
        var lastError: APIError?
        var isInvalidated = false
    }

    private let state = Mutex(State())

    /// The error that stopped all film requests, if any. Nothing is sent after it.
    var stopError: APIError? { state.withLock { $0.stopError } }

    /// The most recent failure of any film request.
    var lastError: APIError? { state.withLock { $0.lastError } }

    var isInvalidated: Bool { state.withLock { $0.isInvalidated } }

    /// Remembers `error` as the last failure; if it stops every request and is the first such error,
    /// latches it and returns true (report it once).
    func record(_ error: APIError) -> Bool {
        state.withLock { state in
            state.lastError = error
            guard error.stopsAllRequests, state.stopError == nil else { return false }
            state.stopError = error
            return true
        }
    }

    func invalidate() {
        state.withLock { $0.isInvalidated = true }
    }
}
