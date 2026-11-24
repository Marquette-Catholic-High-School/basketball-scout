import Foundation

/// Reads a `Retry-After` header (RFC 9110 §10.2.3): whole seconds, which is what the server sends with a
/// 429 `AUTH_THROTTLED` (`max(1, remaining)`, at most 300; 02 §3.3), or an HTTP date.
nonisolated enum RetryAfter {
    /// Seconds to wait, or nil when the value is missing or unreadable. A date in the past gives 0.
    static func seconds(from value: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
            return Int(text).map(TimeInterval.init)
        }
        guard let date = httpDate(text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) or the obsolete RFC 850 form.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
