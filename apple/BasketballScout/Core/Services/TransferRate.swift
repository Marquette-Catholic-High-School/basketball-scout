import Foundation

/// Upload speed as the web measures it (upload.js:410-417): bytes over a sliding 8-second window of
/// samples (at least two kept), reported once the window spans more than half a second.
nonisolated struct TransferRate: Sendable {
    /// The window (upload.js `SPEED_WINDOW_MS`).
    static let window: Double = 8
    /// No speed before the samples span this long.
    static let minimumSpan: Double = 0.5

    private var samples: [(time: Double, bytes: Int)] = []

    init() {}

    /// Forgets the samples (a new run, a resync that moved backwards).
    mutating func reset() {
        samples.removeAll()
    }

    /// Adds a sample (`bytes` sent so far at `time` seconds on a monotonic clock) and returns the speed in
    /// bytes per second, or nil while there is no measurement. Unlike the web, a count that went back
    /// (the server had less than shown) starts a new window instead of giving a negative speed.
    mutating func add(bytes: Int, at time: Double) -> Double? {
        if let last = samples.last, bytes < last.bytes || time < last.time {
            samples.removeAll()
        }
        samples.append((time, bytes))
        while samples.count > 2, time - samples[0].time > Self.window {
            samples.removeFirst()
        }
        let first = samples[0]
        let span = time - first.time
        guard span > Self.minimumSpan else { return nil }
        let speed = Double(bytes - first.bytes) / span
        return speed > 0 ? speed : nil
    }

    /// Seconds left at `bytesPerSecond`; nil without a positive speed.
    static func secondsRemaining(remainingBytes: Int, bytesPerSecond: Double?) -> Double? {
        guard let bytesPerSecond, bytesPerSecond > 0, bytesPerSecond.isFinite else { return nil }
        return Double(max(0, remainingBytes)) / bytesPerSecond
    }
}
