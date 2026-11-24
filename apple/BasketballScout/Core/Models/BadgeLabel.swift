import Foundation

/// A badge's text and colour, e.g. a game's status badge "Film uploaded" in `.warning` (07 §3.5).
nonisolated struct BadgeLabel: Hashable, Sendable {
    var text: String
    var tone: StatusTone
    /// An SF Symbol in front of the text ("Live"); nil for most badges.
    var systemImage: String?

    init(_ text: String, tone: StatusTone, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }
}
