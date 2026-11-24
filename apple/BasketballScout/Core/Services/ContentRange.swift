import Foundation

/// A `Content-Range` response header (04 §4): `bytes 0-1/10240` on a 206, `bytes */10240` on a 416.
nonisolated struct ContentRange: Hashable, Sendable {
    /// First byte sent; nil for `bytes */total`.
    var start: Int64?
    /// Last byte sent, inclusive; nil for `bytes */total`.
    var end: Int64?
    /// Length of the whole file; nil when the server wrote `*`.
    var total: Int64?

    init(start: Int64?, end: Int64?, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// Parses `bytes a-b/total`, `bytes a-b/*` or `bytes */total` (unit case-insensitive, spaces
    /// tolerated). Nil for anything else.
    init?(headerValue: String) {
        let text = headerValue.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes") else { return nil }
        let rest = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangeText = parts[0].trimmingCharacters(in: .whitespaces)
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)

        var total: Int64?
        if totalText != "*" {
            guard let value = Int64(totalText), value >= 0 else { return nil }
            total = value
        }
        if rangeText == "*" {
            guard total != nil else { return nil }
            self.init(start: nil, end: nil, total: total)
            return
        }
        let bounds = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start
        else { return nil }
        if let total, end >= total { return nil }
        self.init(start: start, end: end, total: total)
    }
}
