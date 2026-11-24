import Foundation

/// A polling loop (07 §6, 09 R29): `body` runs at once, then again `interval` after the END of each
/// run (the web measures its 5 s and 3 s from the end of the previous load), until `body` returns
/// false or the task is cancelled.
///
/// Run it from the view that needs it (`.task { await Repeating.every(.seconds(5)) { … } }`), so it
/// stops when the screen goes away; it runs on the caller's actor, so `body` may touch MainActor
/// state. Poll only while the app is active and stop on the lockout gate (09 R6): let `body` return
/// false once `ServerSession.report(_:)` handled an error.
nonisolated enum Repeating {
    /// - Parameters:
    ///   - interval: pause between the end of one run and the start of the next.
    ///   - sleeper: waits `interval`; tests pass one that returns at once.
    ///   - body: one round of work; return false to stop.
    static func every(
        _ interval: Duration,
        sleeper: Sleeper = .live,
        _ body: @escaping () async -> Bool
    ) async {
        while !Task.isCancelled {
            guard await body() else { return }
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
