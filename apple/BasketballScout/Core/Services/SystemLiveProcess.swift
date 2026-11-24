#if os(macOS)
import Foundation
import Synchronization

/// Starts ffmpeg as a child process. The Mac app is sandboxed and ffmpeg inherits its sandbox: it can reach
/// the network and write only inside the app's container (where the parts go). The sandbox runs a program
/// the app can read, which is why `Config/BasketballScout-macOS.entitlements` gives read access to the
/// folders Homebrew installs into; it does not run a file the app wrote itself (those are quarantined).
/// Nothing is written to the app's own output: ffmpeg's messages can contain the stream link, so they are
/// only kept in memory for the status panel (`errorTail()`), and its standard input and output go nowhere.
nonisolated struct SystemLiveProcessLauncher: LiveProcessLauncher {
    func launch(executable: URL, arguments: [String], directory: URL) throws -> any LiveProcess {
        try SystemLiveProcess(executable: executable, arguments: arguments, directory: directory)
    }
}

/// One ffmpeg process.
nonisolated final class SystemLiveProcess: LiveProcess {
    /// How many lines of error output are kept.
    static let tailLength = 12

    private struct State {
        var exitStatus: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var lines: [String] = []
        var partialLine = ""
    }

    /// What the process's callbacks (other threads) and the capture share.
    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let process: Mutex<Process>
    private let shared: Shared

    init(executable: URL, arguments: [String], directory: URL) throws {
        let shared = Shared()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            shared.state.withLock { Self.append(String(decoding: data, as: UTF8.self), to: &$0) }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let waiters = shared.state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                state.exitStatus = status
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: status) }
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        self.shared = shared
        self.process = Mutex(process)
    }

    func interrupt() {
        process.withLock { if $0.isRunning { $0.interrupt() } }
    }

    func terminate() {
        process.withLock { if $0.isRunning { $0.terminate() } }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let finished = shared.state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let finished { continuation.resume(returning: finished) }
        }
    }

    func errorTail() -> [String] {
        shared.state.withLock { state in
            let rest = state.partialLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? state.lines : state.lines + [rest]
        }
    }

    /// Splits ffmpeg's output into lines (it ends progress lines with a carriage return) and keeps the last few.
    private static func append(_ text: String, to state: inout State) {
        state.partialLine += text
        var pieces = state.partialLine.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        state.partialLine = String(pieces.popLast() ?? "")
        for piece in pieces {
            let line = piece.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { state.lines.append(line) }
        }
        if state.lines.count > tailLength { state.lines.removeFirst(state.lines.count - tailLength) }
        if state.partialLine.count > 4000 { state.partialLine = String(state.partialLine.suffix(4000)) }
    }
}
#endif
