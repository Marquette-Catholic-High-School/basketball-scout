#if os(macOS)
import Foundation

/// One finished part of a live capture on this Mac.
nonisolated struct LiveCapturePart: Hashable, Sendable {
    /// Position in the stream, from 0 (the number in its file name).
    var index: Int
    /// `part-00007.mp4`.
    var fileName: String
    /// Its length in seconds (> 0, at most an hour: what the server takes).
    var durationS: Double
}

/// Reads the list ffmpeg keeps of the parts it finished (`-segment_list … -segment_list_type csv`): one line
/// per part, `part-00007.mp4,840.000000,960.133333` (file, start, end in seconds). A part is finished once
/// its line is there, so only whole lines count: the last one may still be being written.
nonisolated enum LivePartsList {
    /// The longest part the server takes (`LiveSegmentInit.duration_s`).
    static let maximumDuration: Double = 3600

    /// The finished parts in `text`, in the list's order. Lines that are not a part are skipped.
    /// - Parameter fallbackDuration: used when a line's times give no length (the part length asked for).
    static func parse(_ text: String, fallbackDuration: Double) -> [LiveCapturePart] {
        guard let end = text.lastIndex(where: \.isNewline) else { return [] }
        return text[..<end].split(whereSeparator: \.isNewline).compactMap { line in
            part(fromLine: line, fallbackDuration: fallbackDuration)
        }
    }

    /// One line of the list; nil when it is not `file,start,end` with a part's file name.
    static func part(fromLine line: Substring, fallbackDuration: Double) -> LiveCapturePart? {
        // The file name comes first and may be quoted; the two times are the last two fields.
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        var name = fields.dropLast(2).joined(separator: ",").trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
        let fileName = (name as NSString).lastPathComponent
        guard let index = LiveFFmpegArguments.partIndex(fileName: fileName) else { return nil }
        let start = Double(fields[fields.count - 2].trimmingCharacters(in: .whitespaces))
        let finish = Double(fields[fields.count - 1].trimmingCharacters(in: .whitespaces))
        return LiveCapturePart(index: index, fileName: fileName, durationS: duration(start: start, end: finish, fallback: fallbackDuration))
    }

    /// `end − start`, kept inside what the server takes; the fallback when the times give no length.
    static func duration(start: Double?, end: Double?, fallback: Double) -> Double {
        var seconds = fallback
        if let start, let end, start.isFinite, end.isFinite, end - start > 0 { seconds = end - start }
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return (min(seconds, maximumDuration) * 1_000_000).rounded() / 1_000_000
    }
}
#endif
