import SwiftUI

extension View {
    /// Registers the screens pushed on a game page (`GameRoute`) and gives them the game's `GameContext`.
    /// Apply it to the game page's content inside the detail `NavigationStack` (the shell's `GameView`
    /// does).
    func gameRouteDestinations(for context: GameContext) -> some View {
        navigationDestination(for: GameRoute.self) { route in
            GameRouteDestination(route: route, context: context)
        }
    }
}

/// One pushed screen of a game.
private struct GameRouteDestination: View {
    let route: GameRoute
    let context: GameContext

    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch route {
        case .roster:
            RosterView()
                .environment(context)
        case .film:
            FilmUploadView(gameID: context.gameID) {
                // Back to the game, which follows the new film's analysis (04 §6.1: "opening the game").
                appModel.pop(.film)
                Task { await context.refresh() }
            }
            .environment(context)
        }
    }
}
