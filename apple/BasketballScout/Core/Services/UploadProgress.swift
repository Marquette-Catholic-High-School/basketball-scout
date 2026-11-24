import Foundation
import Synchronization

/// Bytes of one upload: what the server confirmed plus what has left the device for the chunk in
/// flight (the web's progress counts both, upload.js:420). Written by the run and by URLSession's
/// progress callbacks, read by the manager's progress ticker.
nonisolated final class UploadProgress: Sendable {
    private struct State {
        var committed = 0
        var inFlight = 0
        /// Bumped for every chunk and every reset, so a late callback of an older chunk is ignored.
        var generation = 0
    }

    private let state = Mutex(State())

    /// Confirmed bytes plus the chunk in flight.
    var bytesSent: Int { state.withLock { $0.committed + $0.inFlight } }

    /// Bytes the server confirmed.
    var committed: Int { state.withLock { $0.committed } }

    /// The server has `received` bytes; nothing is in flight.
    func set(committed received: Int) {
        state.withLock { state in
            state.committed = max(0, received)
            state.inFlight = 0
            state.generation += 1
        }
    }

    /// Starts a chunk; the returned handler reports its bytes sent (for `APIClient.uploadChunk`).
    func beginChunk() -> UploadProgressHandler {
        let generation = state.withLock { state in
            state.generation += 1
            state.inFlight = 0
            return state.generation
        }
        return { [self] sent, _ in
            state.withLock { state in
                guard state.generation == generation else { return }
                state.inFlight = Int(clamping: max(0, sent))
            }
        }
    }
}
