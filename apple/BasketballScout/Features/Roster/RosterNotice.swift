import Foundation

/// A notice the roster page shows (the web's `notice(kind, title, message, hint)` plus its one button), as
/// data so the page model can decide it and tests can read it.
nonisolated struct RosterNotice: Hashable, Sendable {
    /// The notice's one button.
    nonisolated enum Action: Hashable, Sendable {
        /// Back to the game page ("Open the game page"), which says how the analysis went.
        case openGamePage
        /// Load the page's data again ("Reload the page").
        case reloadPage

        var title: String {
            switch self {
            case .openGamePage: RosterText.openGamePage
            case .reloadPage: RosterText.reloadPage
            }
        }
    }

    var tone: StatusTone
    var title: String
    var message: String?
    var hint: String?
    var action: Action?

    init(tone: StatusTone, title: String, message: String? = nil, hint: String? = nil, action: Action? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.hint = hint
        self.action = action
    }
}
