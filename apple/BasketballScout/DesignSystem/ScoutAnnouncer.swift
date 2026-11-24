import SwiftUI

/// VoiceOver announcements, the native stand-in for the web's live regions (07 §8, §5.6):
/// error boxes are "assertive" (high priority), toasts and status lines "polite".
enum ScoutAnnouncer {
    enum Priority {
        /// Interrupts other speech (errors).
        case high
        /// Waits for current speech (toasts, stage changes).
        case normal
    }

    /// Speaks `text` with VoiceOver (no effect when VoiceOver is off). Empty text is ignored.
    static func announce(_ text: String, priority: Priority = .normal) {
        guard let text = ServerText.nonEmpty(text) else { return }
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = priority == .high ? .high : .default
        AccessibilityNotification.Announcement(message).post()
    }
}

extension View {
    /// Announces `text` to VoiceOver when it changes (not when the view first appears), like a
    /// polite live region: use it for job stage lines and similar status text, so polling that
    /// rewrites the same text stays silent (07 §5.6).
    func announcesChanges(of text: String?, priority: ScoutAnnouncer.Priority = .normal) -> some View {
        onChange(of: text) { _, newValue in
            if let newValue { ScoutAnnouncer.announce(newValue, priority: priority) }
        }
    }
}
