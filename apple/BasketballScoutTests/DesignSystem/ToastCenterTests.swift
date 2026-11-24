import Foundation
import Testing
@testable import BasketballScout

/// A sleeper the test controls: `sleep` waits until `releaseAll()` or until its task is cancelled.
private nonisolated final class GateSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var cancelCount = 0

    var pendingCount: Int { lock.withLock { waiters.count } }
    var cancellations: Int { lock.withLock { cancelCount } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = lock.withLock {
                    if cancelledIDs.contains(id) { return true }
                    waiters[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock {
                cancelCount += 1
                cancelledIDs.insert(id)
                return waiters.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        let all = lock.withLock {
            let current = waiters
            waiters = [:]
            return current
        }
        for continuation in all.values { continuation.resume() }
    }
}

@MainActor
@Suite("ToastCenter")
struct ToastCenterTests {
    /// Polls (yielding, then 1 ms naps) until `condition` holds or about two seconds pass.
    private func waitUntil(_ condition: () -> Bool) async {
        for attempt in 0..<2000 where !condition() {
            if attempt < 50 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @Test("show puts the toast on screen and announces it")
    func showAnnounces() {
        var spoken: [String] = []
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { spoken.append($0) })
        center.show("Analysis started")
        #expect(center.current?.text == "Analysis started")
        #expect(center.current?.tone == .neutral)
        center.show("Scouting report ready", tone: .success)
        #expect(center.current?.text == "Scouting report ready")
        #expect(center.current?.tone == .success)
        #expect(spoken == ["Analysis started", "Scouting report ready"])
        center.dismiss()
    }

    @Test("empty text is ignored")
    func emptyText() {
        var spoken: [String] = []
        let center = ToastCenter(sleep: { _ in }, announce: { spoken.append($0) })
        center.show("   ")
        #expect(center.current == nil)
        #expect(spoken.isEmpty)
    }

    @Test("the toast hides itself after the display time")
    func autoDismiss() async {
        let center = ToastCenter(sleep: { _ in }, announce: { _ in })
        center.show("Roster saved")
        #expect(center.current != nil)
        await waitUntil { center.current == nil }
        #expect(center.current == nil)
    }

    @Test("a new toast replaces the old one and restarts the timer")
    func replaceRestartsTimer() async {
        let gate = GateSleeper()
        let center = ToastCenter(sleep: { try await gate.sleep($0) }, announce: { _ in })
        center.show("Deleted Riverside vs Eastwood")
        await waitUntil { gate.pendingCount == 1 }
        #expect(gate.pendingCount == 1)

        center.show("Analysis started")
        // The first timer is cancelled; only the new one waits.
        await waitUntil { gate.cancellations == 1 && gate.pendingCount == 1 }
        #expect(gate.cancellations == 1)
        #expect(gate.pendingCount == 1)
        #expect(center.current?.text == "Analysis started")

        gate.releaseAll()
        await waitUntil { center.current == nil }
        #expect(center.current == nil)
    }

    @Test("an old timer never hides a newer toast")
    func staleExpiry() {
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
        center.show("First")
        let firstID = center.current!.id
        center.show("Second")
        center.expire(firstID)
        #expect(center.current?.text == "Second")
        center.expire(center.current!.id)
        #expect(center.current == nil)
    }

    @Test("dismiss hides at once and stops the timer")
    func dismiss() async {
        let gate = GateSleeper()
        let center = ToastCenter(sleep: { try await gate.sleep($0) }, announce: { _ in })
        center.show("Copied")
        await waitUntil { gate.pendingCount == 1 }
        center.dismiss()
        #expect(center.current == nil)
        await waitUntil { gate.cancellations == 1 }
        #expect(gate.cancellations == 1)
    }

    @Test("defaults: 4 seconds, like the web")
    func defaults() {
        let center = ToastCenter()
        #expect(center.displayDuration == .seconds(4))
        #expect(center.current == nil)
    }
}
