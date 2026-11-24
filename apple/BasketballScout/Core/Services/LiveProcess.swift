#if os(macOS)
import Foundation

/// A running ffmpeg, as the live capture sees it. `SystemLiveProcess` is the real one; tests drive a fake.
nonisolated protocol LiveProcess: Sendable {
    /// Asks it to finish (SIGINT): ffmpeg closes the part it is writing, adds it to the list and exits.
    func interrupt()
    /// Stops it without waiting for the part (SIGTERM), for a process that did not finish on its own.
    func terminate()
    /// Returns its exit status once it has exited (at once when it already has).
    func waitForExit() async -> Int32
    /// The last lines it wrote to its error output, oldest first. They can contain the stream link: pass
    /// them through `LiveCaptureLog` before showing them, and never log them.
    func errorTail() -> [String]
}

/// Starts ffmpeg for the live capture.
nonisolated protocol LiveProcessLauncher: Sendable {
    /// Runs `executable` with `arguments` in `directory`. Throws when it cannot be started at all.
    func launch(executable: URL, arguments: [String], directory: URL) throws -> any LiveProcess
}
#endif
