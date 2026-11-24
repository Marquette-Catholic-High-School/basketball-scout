import SwiftUI

/// The game page (03 §7.3–§7.7): the root of the detail column's navigation stack for the selected game.
///
/// It creates the page's `GameContext` once (`GameContext(gameID:appModel:)`, so ⌘R reaches it) and the
/// page's `GameDetailModel`, puts both in the environment, registers the pushed screens (`GameRoute.roster`,
/// `.film`) and runs the context with `.taskWhileActive`: it loads on appear and again when the app returns to
/// the foreground, follows running jobs, and stops polling when the page is hidden or the app goes to the
/// background (09 R29). While the page is the top screen of its window it publishes itself for the app's menus
/// (`GamePageFocus`, `focusedSceneValue`).
///
/// The context exists from the very first render (`GameViewParts`), so the pushed screens' destinations are
/// registered before any route is resolved. A route asked for together with a new selection (the games list's
/// Roster, Add film, Show upload: `AppModel.open(gameID:route:)`) is pushed when the page appears: a collapsed
/// split view (iPhone) pushes the page for the selection first and drops a route set in the same update.
///
/// The sections follow the web's order: header and actions, page error, job panel, team banner, "No film
/// yet", pending notice, film + event timeline, analysis tabs (`GameDetailPage`).
struct GameView: View {
    let gameID: String

    @Environment(AppModel.self) private var appModel
    @State private var parts = GameViewParts()

    init(gameID: String) {
        self.gameID = gameID
    }

    var body: some View {
        let (context, model) = parts.parts(for: gameID, appModel: appModel)
        GameDetailPage()
            .environment(context)
            .environment(model)
            .gameRouteDestinations(for: context)
            .onAppear { appModel.gamePageAppeared(gameID) }
            .taskWhileActive { await context.run() }
            .focusedSceneValue(\.gamePage, appModel.gamePath.isEmpty ? GamePageFocus(context: context, model: model) : nil)
    }
}

/// The game page's context and model, made on the first render of `GameView` (not in `onAppear`, one update
/// later), so `.gameRouteDestinations(for:)` is registered before a route pushed together with the selection
/// is resolved. Not observable: making them changes nothing on screen.
final class GameViewParts {
    private(set) var context: GameContext?
    private(set) var model: GameDetailModel?

    /// The page's parts for `gameID`, made at the first call (and again only for another game).
    func parts(for gameID: String, appModel: AppModel) -> (GameContext, GameDetailModel) {
        if let context, let model, context.gameID == gameID { return (context, model) }
        let newContext = GameContext(gameID: gameID, appModel: appModel)
        #if os(macOS)
        let newModel = GameDetailModel(context: newContext, toasts: appModel.toasts, liveCapture: appModel.liveCapture)
        #else
        let newModel = GameDetailModel(context: newContext, toasts: appModel.toasts)
        #endif
        context = newContext
        model = newModel
        return (newContext, newModel)
    }
}

#Preview("GameDetail – page from the games list") {
    let appModel = AppModel.preview(games: [GameDetailPreviewData.game()])
    NavigationStack {
        GameView(gameID: GameDetailPreviewData.gameID)
    }
    .withAppEnvironment(appModel)
}
