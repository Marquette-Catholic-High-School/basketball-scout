#if os(macOS)
import Foundation
import Testing
@testable import BasketballScout

/// The capture with a real child process: a shell script stands in for ffmpeg. It is given ffmpeg's real
/// command line (`LiveFFmpegArguments`), writes parts and their list as ffmpeg's segment muxer does, and on
/// an interrupt (SIGINT) closes its last part before it exits, as ffmpeg does.
@MainActor
struct SystemLiveProcessTests {
    /// Reads the options the capture passes (`-segment_start_number`, `-segment_list`, `-i`, the part pattern
    /// as the last argument). Under a name that ends in `-fails` it only complains and exits, as ffmpeg does
    /// when the camera cannot be reached.
    private static let script = #"""
    #!/bin/sh
    start=0
    list=""
    link=""
    last=""
    prev=""
    for arg in "$@"; do
      case "$prev" in
        -segment_start_number) start="$arg" ;;
        -segment_list) list="$arg" ;;
        -i) link="$arg" ;;
      esac
      prev="$arg"
      last="$arg"
    done
    dir=$(dirname "$last")
    part() {
      name=$(printf 'part-%05d.mp4' "$1")
      printf '\000\000\000\030ftypmp42%s' "$2" > "$dir/$name"
      printf '%s,%s.000000,%s.500000\n' "$name" "$(($1 * 120))" "$(($1 * 120 + $3))" >> "$list"
    }
    case "$(basename "$0")" in
      *-fails) echo "[rtmp @ 0x600003e1c000] Connection to $link failed: Connection refused" >&2
               echo "Error opening input file $link." >&2
               exit 1 ;;
    esac
    finish() {
      part $((start + 2)) "the-last-part" 7
      exit 255
    }
    trap finish INT
    part "$start" "first" 120
    part $((start + 1)) "second" 120
    printf 'unfinished' > "$dir/$(printf 'part-%05d.mp4' $((start + 2)))"
    while :; do sleep 0.05; done
    """#

    /// Runs the stand-in through `/bin/sh`: the test host is sandboxed like the app, and the sandbox does
    /// not run a file the app wrote itself. (`$0` is still the script, and SIGINT reaches its trap.)
    private struct ShellLauncher: LiveProcessLauncher {
        func launch(executable: URL, arguments: [String], directory: URL) throws -> any LiveProcess {
            try SystemLiveProcessLauncher().launch(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [executable.path(percentEncoded: false)] + arguments, directory: directory)
        }
    }

    private func makeScript(named name: String, in folder: ServiceTestFolder) throws -> URL {
        let file = folder.url.appending(path: name, directoryHint: .notDirectory)
        let lines = Self.script.split(separator: "\n", omittingEmptySubsequences: false).map { $0.drop(while: { $0 == " " }) }
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }

    @Test func aRealProcessIsCapturedInterruptedAndItsLastPartSent() async throws {
        let scripts = try ServiceTestFolder("LiveScript")
        defer { scripts.remove() }
        let stand = try makeScript(named: "ffmpeg-stand-in", in: scripts)
        let h = try LiveCaptureHarness()
        defer { h.cleanUp() }
        h.api.alreadyHas(0, 1, 2)  // so the numbering starts at 3
        var dependencies = h.dependencies
        dependencies.launcher = ShellLauncher()
        let capture = LiveCaptureController(
            gameID: h.gameID, mode: .capture(link: try h.link, ffmpeg: stand), folder: h.folder, dependencies: dependencies)

        try await capture.start()
        try await waitUntil("two parts on the server") { capture.partsSent == 2 }
        #expect(capture.phase == .capturing)
        #expect(h.api.parts.keys.sorted() == [3, 4])
        #expect(h.api.parts[3] == Data([0, 0, 0, 0x18]) + Data("ftypmp42first".utf8))
        #expect(h.api.durations[3] == 120.5)
        #expect(h.files.contains("part-00005.mp4"))  // being written, not listed: not sent

        // "End live game": SIGINT, the process closes its last part and exits, the part is sent, then finish.
        capture.end()
        try await waitUntil("the capture to end") { !capture.isActive }

        #expect(capture.phase == .ended(.finished))
        #expect(h.api.parts.keys.sorted() == [3, 4, 5])
        #expect(h.api.parts[5] == Data([0, 0, 0, 0x18]) + Data("ftypmp42the-last-part".utf8))
        #expect(h.api.durations[5] == 7.5)
        #expect(h.api.calls.last == .finish)
        #expect(!h.folder.exists)
    }

    @Test func aRealProcessThatExitsLeavesItsLastWordsWithoutTheLink() async throws {
        let scripts = try ServiceTestFolder("LiveScript")
        defer { scripts.remove() }
        let stand = try makeScript(named: "ffmpeg-fails", in: scripts)
        let folder = try scripts.folder("game")
        let link = try LiveStreamLink(userInput: "rtmp://192.168.1.50/live/secretkey123")
        let arguments = LiveFFmpegArguments.make(link: link, segmentSeconds: 120, startNumber: 0, directory: folder, run: 0)

        let process = try ShellLauncher().launch(executable: stand, arguments: arguments, directory: folder)
        let status = await process.waitForExit()

        #expect(status == 1)
        #expect(await process.waitForExit() == 1)  // asked again after the exit
        // The pipe may hand over the last bytes a moment after the exit.
        try await waitUntil("its error output") { process.errorTail().count == 2 }
        let tail = process.errorTail()
        #expect(tail.last == "Error opening input file rtmp://192.168.1.50/live/secretkey123.")
        #expect(LiveCaptureLog.problem(from: tail, link: link) == "Error opening input file the stream.")
        // Interrupting or killing a process that is gone does nothing.
        process.interrupt()
        process.terminate()
    }

    @Test func aProgramThatIsNotThereCannotBeLaunched() throws {
        let scripts = try ServiceTestFolder("LiveScript")
        defer { scripts.remove() }
        #expect(throws: (any Error).self) {
            _ = try SystemLiveProcessLauncher().launch(
                executable: scripts.url.appending(path: "no-ffmpeg-here"), arguments: [], directory: scripts.url)
        }
    }
}
#endif
