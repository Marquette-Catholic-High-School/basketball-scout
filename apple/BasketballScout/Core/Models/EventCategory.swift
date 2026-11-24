import Foundation

/// The web's colour groups for timeline events and video markers (labels.js:27-58, 06 §5.2, 07 §10.2), in
/// legend order. `rawValue` is the key the design system's `Theme.eventColor(categoryKey:)` takes.
nonisolated enum EventCategory: String, CaseIterable, Hashable, Sendable {
    case make
    case miss
    case rebound
    case assist
    case defense
    case turnover
    case foul
    case game
    case other

    /// Legend label (labels.js CATEGORY_LABELS): "Makes", "Misses", "Rebounds", "Assists", "Steals / blocks",
    /// "Turnovers", "Fouls", "Game events", "Other".
    var label: String {
        switch self {
        case .make: "Makes"
        case .miss: "Misses"
        case .rebound: "Rebounds"
        case .assist: "Assists"
        case .defense: "Steals / blocks"
        case .turnover: "Turnovers"
        case .foul: "Fouls"
        case .game: "Game events"
        case .other: "Other"
        }
    }

    /// The key for `Theme.eventColor(categoryKey:)`.
    var key: String { rawValue }
}
