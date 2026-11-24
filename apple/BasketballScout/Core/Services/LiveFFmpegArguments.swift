#if os(macOS)
import Foundation

/// The command line of the ffmpeg that reads a live stream and cuts it into parts (docs/LIVE.md "What a
/// capture client does"): MP4 parts of `segmentSeconds`, the video copied without re-encoding, each part
/// starting on a key frame and playable on its own, numbered in stream order.
///
/// ```
/// ffmpeg -hide_banner -nostdin -loglevel warning -rw_timeout 15000000 -i <link>
///   -map 0:v:0 -map 0:a:0? -c:v copy -c:a aac -b:a 96k
///   -f segment -segment_time <seconds> -segment_format mp4 -segment_format_options movflags=+faststart
///   -reset_timestamps 1 -segment_start_number <next index>
///   -segment_list <dir>/parts-<run>.csv -segment_list_type csv <dir>/part-%05d.mp4
/// ```
///
/// ffmpeg appends a line to the list file when a part is finished (`LivePartsList`). Every run of ffmpeg
/// (after the stream was lost) writes its own list, so an earlier run's list is never overwritten.
nonisolated enum LiveFFmpegArguments {
    /// How long ffmpeg waits for the stream before it gives up and exits, in microseconds (15 s). The capture
    /// then starts it again.
    static let inputTimeoutMicroseconds = 15_000_000

    /// The arguments after `ffmpeg`.
    /// - Parameters:
    ///   - link: the stream link (a secret: never log these arguments).
    ///   - segmentSeconds: the part length the server asked for (`LiveInfo.segmentSeconds`).
    ///   - startNumber: the index of the first part this run writes.
    ///   - directory: the game's capture folder.
    ///   - run: this run's number in the folder (names its list file).
    static func make(link: LiveStreamLink, segmentSeconds: Int, startNumber: Int, directory: URL, run: Int) -> [String] {
        let folder = directory.path(percentEncoded: false)
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return ["-hide_banner", "-nostdin", "-loglevel", "warning"]
            + inputOptions(scheme: link.scheme)
            + [
                "-i", link.value,
                "-map", "0:v:0", "-map", "0:a:0?",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "96k",
                "-f", "segment",
                "-segment_time", String(max(segmentSeconds, 1)),
                "-segment_format", "mp4",
                "-segment_format_options", "movflags=+faststart",
                "-reset_timestamps", "1",
                "-segment_start_number", String(max(startNumber, 0)),
                "-segment_list", base + listFileName(run: run),
                "-segment_list_type", "csv",
                base + partPattern,
            ]
    }

    /// The options in front of `-i` that make ffmpeg give up on a silent stream instead of waiting forever.
    /// `-rw_timeout` belongs to ffmpeg's network I/O layer, which RTSP does not use: an RTSP link takes the
    /// RTSP reader's own `-timeout`, over TCP (cameras drop UDP packets on a busy Wi-Fi).
    static func inputOptions(scheme: String) -> [String] {
        let timeout = String(inputTimeoutMicroseconds)
        if scheme == "rtsp" { return ["-rtsp_transport", "tcp", "-timeout", timeout] }
        return ["-rw_timeout", timeout]
    }

    /// ffmpeg's pattern for the part files: `part-00007.mp4`.
    static let partPattern = "part-%05d.mp4"

    /// `part-00007.mp4`.
    static func partFileName(index: Int) -> String {
        let digits = String(max(index, 0))
        return "part-" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits + ".mp4"
    }

    /// The index in a part's file name (`part-00007.mp4` → 7); nil for any other name.
    static func partIndex(fileName: String) -> Int? {
        guard fileName.hasPrefix("part-"), fileName.hasSuffix(".mp4") else { return nil }
        let digits = fileName.dropFirst(5).dropLast(4)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// `parts-3.csv`: the list of the parts run 3 finished.
    static func listFileName(run: Int) -> String {
        "parts-\(max(run, 0)).csv"
    }

    /// The run in a list file's name (`parts-3.csv` → 3); nil for any other name.
    static func listRun(fileName: String) -> Int? {
        guard fileName.hasPrefix("parts-"), fileName.hasSuffix(".csv") else { return nil }
        let digits = fileName.dropFirst(6).dropLast(4)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
#endif
