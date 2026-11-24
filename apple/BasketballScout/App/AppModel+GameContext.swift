import Foundation

extension GameContext {
    /// The page context of `gameID` with the app's parts, registered with the app model (⌘R refreshes it).
    convenience init(gameID: String, appModel: AppModel) {
        self.init(
            gameID: gameID,
            session: appModel.session,
            uploads: appModel.uploads,
            gamesStore: appModel.games,
            toasts: appModel.toasts)
        appModel.register(self)
    }
}
