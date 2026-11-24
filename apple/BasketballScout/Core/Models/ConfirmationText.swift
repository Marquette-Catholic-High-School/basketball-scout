import Foundation

/// A confirmation's texts. The web shows one `window.confirm` string whose paragraphs are separated by a
/// blank line; natively the first paragraph is the dialog title and the rest its message.
nonisolated struct ConfirmationText: Hashable, Sendable {
    var title: String
    var message: String?

    init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    /// The web's single string (`title`, a blank line, `message`).
    var webText: String {
        guard let message, !message.isEmpty else { return title }
        return title + "\n\n" + message
    }
}
