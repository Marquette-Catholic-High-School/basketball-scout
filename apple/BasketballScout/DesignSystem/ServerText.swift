import Foundation

/// Helpers for showing server-provided text (error hints, job messages) the way 07 §12 and
/// 09 R25 / R47 ask: verbatim, with administrator instructions kept out of the coach's way.
nonisolated enum ServerText {
    /// The text, or nil when it is nil, empty or only whitespace. The text itself is not changed.
    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// True when the text is an instruction for the server administrator: it contains backticks or
    /// a shell command ("sudo systemctl …", "python -m …", "modal token new", "apt install …",
    /// nginx's `client_max_body_size`). Such hints go behind "Technical details (for IT staff)".
    /// Plain advice that only names a setting ("Raise SCOUT_MAX_UPLOAD_GB in .env or compress the
    /// film.") stays visible, because it also tells the coach what they can do.
    static func isTechnical(_ text: String) -> Bool {
        if text.contains("`") { return true }
        let lowered = text.lowercased()
        return commandMarkers.contains { lowered.contains($0) }
    }

    private static let commandMarkers = [
        "sudo ", "systemctl ", "journalctl ", "apt install ", "apt-get ", "brew install ", "pip install ",
        "python -m ", "python3 ", "modal token ", "modal deploy ", "modal app ", "scripts/", "deploy/",
        "client_max_body_size", "docker ", "certbot ", "tailscale serve",
    ]

    /// Joins non-empty parts as sentences: "Title. Message" (no extra period after "?", "!", "." or ":").
    static func sentences(_ parts: [String?]) -> String {
        var result = ""
        for part in parts.compactMap({ nonEmpty($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if result.isEmpty {
                result = part
            } else if let last = result.last, ".?!:…".contains(last) {
                result += " " + part
            } else {
                result += ". " + part
            }
        }
        return result
    }
}
