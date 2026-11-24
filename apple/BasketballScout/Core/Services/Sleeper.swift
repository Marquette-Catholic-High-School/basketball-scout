import Foundation

/// Waits for a duration. Pollers, upload back-off and repeating loops take one, so tests can run
/// their timers at once and record the waits instead of depending on the wall clock (DESIGN §7).
nonisolated struct Sleeper: Sendable {
    private let body: @Sendable (Duration) async throws -> Void

    /// - Parameter body: suspends for the given duration; must throw `CancellationError` when the
    ///   waiting task is cancelled (as `Task.sleep` does).
    init(_ body: @escaping @Sendable (Duration) async throws -> Void) {
        self.body = body
    }

    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws {
        try await body(duration)
    }

    /// The real clock (`Task.sleep(for:)`).
    static let live = Sleeper { try await Task.sleep(for: $0) }
}
