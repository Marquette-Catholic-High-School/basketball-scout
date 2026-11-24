import Foundation

/// The symbol in front of a timeline row, drawn in its category colour (06 §5.2, 07 §10.2). The web uses
/// a coloured square; a shape per category also tells the categories apart without colour (07 §8).
nonisolated enum PlayerEventSymbol {
    static func name(for category: EventCategory) -> String {
        switch category {
        case .make: "checkmark.circle.fill"
        case .miss: "xmark.circle.fill"
        case .rebound: "arrow.down.circle.fill"
        case .assist: "arrowshape.turn.up.right.circle.fill"
        case .defense: "shield.fill"
        case .turnover: "arrow.uturn.backward.circle.fill"
        case .foul: "exclamationmark.circle.fill"
        case .game: "clock.fill"
        case .other: "circle.fill"
        }
    }
}
