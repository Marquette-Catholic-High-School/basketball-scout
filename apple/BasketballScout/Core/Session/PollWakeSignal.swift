import Foundation

/// Lets an idle polling loop sleep until something wakes it (a game became active, "Try again"), or its
/// task is cancelled. A signal that arrives while nobody waits is kept for the next wait.
final class PollWakeSignal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pending = false

    /// Returns when `signal()` is called (or was called since the last wait), or the task is cancelled.
    func wait() async {
        if pending {
            pending = false
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
    }

    /// Wakes every waiting loop (or the next one to wait).
    func signal() {
        guard !waiters.isEmpty else {
            pending = true
            return
        }
        let current = waiters
        waiters.removeAll()
        for continuation in current.values { continuation.resume() }
    }

    /// Forgets a signal nobody waited for.
    func reset() {
        pending = false
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
