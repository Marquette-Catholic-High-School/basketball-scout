import Foundation

/// A notice's texts as the web shows them: an optional bold title, the message and a muted hint (07 §5.1).
nonisolated struct NoticeText: Hashable, Sendable {
    var tone: StatusTone
    var title: String?
    var message: String
    var hint: String?

    init(tone: StatusTone, title: String? = nil, message: String, hint: String? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.hint = hint
    }
}
