import Foundation

/// Screens pushed on top of a game page in the detail `NavigationStack` (07 §1.2). Push one with
/// `NavigationLink(value: GameRoute.roster)` or `AppModel.navigate(to:)`; the game page registers the
/// destinations with `.gameRouteDestinations(for:)`, which also puts the game's `GameContext` in their
/// environment. Pop with `@Environment(\.dismiss)`.
nonisolated enum GameRoute: Hashable, Sendable {
    /// "Roster & jerseys": `RosterView()` (both rosters and the jersey assignments).
    case roster
    /// "Add film" / "Replace film": `FilmUploadView(gameID:onFinished:)`.
    case film
}
