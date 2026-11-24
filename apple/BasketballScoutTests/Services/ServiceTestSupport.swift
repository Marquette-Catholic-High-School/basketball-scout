import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// A sleeper that returns at once (after a yield) and records every wait: deterministic back-off.
nonisolated final class RecordingSleeper: Sendable {
    private let waits = Mutex<[Duration]>([])

    /// Every wait that started (not those asked for by an already cancelled task), in order.
    var recorded: [Duration] { waits.withLock { $0 } }

    var sleeper: Sleeper {
        Sleeper { [self] duration in
            try Task.checkCancellation()
            waits.withLock { $0.append(duration) }
            await Task.yield()
            try Task.checkCancellation()
        }
    }
}

/// A thread-safe counter for stub handlers.
nonisolated final class ServiceCounter: Sendable {
    private let value = Mutex(0)

    /// Returns the current count and adds one.
    func next() -> Int {
        value.withLock { count in
            defer { count += 1 }
            return count
        }
    }

    var count: Int { value.withLock { $0 } }
}

/// The test failed waiting for something.
nonisolated struct WaitTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Waits until `condition` holds, checking every 2 ms; the timeout only guards against a hang.
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(what)")
            throw WaitTimeout(what: what)
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Temporary folders and films for one test (inside the app's container on macOS).
nonisolated struct ServiceTestFolder: Sendable {
    let url: URL

    init(_ name: String = "ServicesTests") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A subfolder (created).
    func folder(_ name: String) throws -> URL {
        let folder = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Deterministic bytes standing in for a film (`seed` makes different files of the same size).
    static func filmBytes(count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ 7 &+ seed &* 13) % 251) })
    }

    /// Writes `count` deterministic bytes to `name` in this folder.
    @discardableResult
    func makeFilm(_ name: String = "Test Film.mp4", count: Int, seed: Int = 0, in subfolder: String? = nil) throws -> URL {
        let base = try subfolder.map(folder) ?? url
        let file = base.appending(path: name, directoryHint: .notDirectory)
        try Self.filmBytes(count: count, seed: seed).write(to: file)
        return file
    }
}

/// The app life cycle as the upload manager sees it, driven by the test.
@MainActor
final class FakeUploadActivity: UploadActivityMonitor {
    var onBackgroundTimeExpiring: (() -> Void)?
    var onBecameActive: (() -> Void)?
    /// Every change of "uploads running".
    private(set) var changes: [Bool] = []

    var isRunning: Bool { changes.last ?? false }

    func uploadsDidChange(running: Bool) {
        if changes.last != running { changes.append(running) }
    }

    func expireBackgroundTime() { onBackgroundTimeExpiring?() }

    func becomeActive() { onBecameActive?() }
}

/// Records what the manager passed to its error reporter.
@MainActor
final class ReportedErrors {
    private(set) var errors: [any Error] = []

    var apiErrors: [APIError] { errors.compactMap { $0 as? APIError } }

    func record(_ error: any Error) { errors.append(error) }
}
