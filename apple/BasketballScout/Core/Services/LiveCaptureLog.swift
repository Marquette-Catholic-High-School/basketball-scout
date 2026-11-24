#if os(macOS)
import Foundation

/// Turns ffmpeg's last error lines into the status panel's "Last problem", without the stream link: ffmpeg
/// repeats the link (and with it a stream key or password) in its messages.
nonisolated enum LiveCaptureLog {
    /// What stands in for a link in a message.
    static let placeholder = "the stream"
    /// The longest text the panel shows.
    static let maximumLength = 200

    /// The last line worth showing, with every link taken out; nil when there is none.
    static func problem(from lines: [String], link: LiveStreamLink?) -> String? {
        for line in lines.reversed() {
            let cleaned = redact(line, link: link).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            return cleaned.count > maximumLength ? String(cleaned.prefix(maximumLength)) + "\u{2026}" : cleaned
        }
        return nil
    }

    /// `text` without the stream link: the link itself, anything else that looks like a link, and the
    /// link's secret pieces (password, query, a long last path component) wherever ffmpeg repeats them alone.
    static func redact(_ text: String, link: LiveStreamLink?) -> String {
        var result = text
        if let link {
            result = result.replacingOccurrences(of: link.value, with: placeholder, options: .caseInsensitive)
        }
        result = result.replacing(/[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s'"<>\]\)]+/, with: placeholder)
        if let link {
            for secret in secrets(of: link) {
                result = result.replacingOccurrences(of: secret, with: "\u{2026}")
            }
        }
        // ffmpeg names its reader with a memory address ("[rtmp @ 0x600003e1c000]"), which says nothing to a coach.
        result = result.replacing(/\[[A-Za-z0-9_#:.,\- ]+ @ 0x[0-9a-fA-F]+\]\s*/, with: "")
        return result
    }

    /// The pieces of a link that are secret on their own: the password, the query (stream keys, pass
    /// phrases) and a last path component long enough to be a key.
    static func secrets(of link: LiveStreamLink) -> [String] {
        var found: [String] = []
        let components = URLComponents(string: link.value)
        if let password = components?.password, password.count >= 3 { found.append(password) }
        if let query = components?.percentEncodedQuery, query.count >= 3 { found.append(query) }
        for item in components?.queryItems ?? [] {
            if let value = item.value, value.count >= 6 { found.append(value) }
        }
        let path = components?.path ?? link.value
        if let last = path.split(separator: "/").last, last.count >= 6 { found.append(String(last)) }
        return found.sorted { $0.count > $1.count }
    }
}
#endif
