import Foundation

/// A `Range: bytes=…` request for the film (04 §4: Starlette `FileResponse`, 206 with `Content-Range`;
/// 09 R11). Only single ranges are sent: a multi-range request would come back as
/// `multipart/byteranges`.
nonisolated struct ByteRange: Hashable, Sendable, CustomStringConvertible {
    /// First byte (0-based).
    var start: Int64
    /// Last byte, inclusive; nil = to the end of the file.
    var end: Int64?

    init(start: Int64, end: Int64? = nil) {
        self.start = start
        self.end = end
    }

    /// `bytes=100-199` or `bytes=100-`.
    var headerValue: String {
        if let end { return "bytes=\(start)-\(end)" }
        return "bytes=\(start)-"
    }

    /// Number of bytes asked for; nil when open-ended.
    var length: Int64? {
        end.map { $0 - start + 1 }
    }

    var description: String { headerValue }

    /// What an AVFoundation data request still needs: from `currentOffset` (bytes before it were
    /// already delivered) to the end of the resource, or to `requestedOffset + requestedLength - 1`.
    /// The end is clamped to a known `contentLength`. Nil when nothing is left to load.
    static func remaining(
        requestedOffset: Int64,
        requestedLength: Int,
        currentOffset: Int64,
        toEndOfResource: Bool,
        contentLength: Int64?
    ) -> ByteRange? {
        let start = max(currentOffset, requestedOffset, 0)
        var end: Int64?
        if !toEndOfResource {
            guard requestedLength > 0 else { return nil }
            let (sum, overflow) = requestedOffset.addingReportingOverflow(Int64(requestedLength) - 1)
            end = overflow ? nil : sum
        }
        if let contentLength {
            guard start < contentLength else { return nil }
            end = min(end ?? contentLength - 1, contentLength - 1)
        }
        if let end, end < start { return nil }
        return ByteRange(start: start, end: end)
    }
}
