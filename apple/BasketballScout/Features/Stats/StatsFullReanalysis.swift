import Foundation

/// "Full re-analysis" from the Data quality tab (03 §7.4, 06 §12): after the coach confirmed
/// (`Game.fullReanalysisConfirmation`), `POST /api/games/{id}/jobs {"kind":"analyze"}` through the page's
/// `GameContext` (which follows the job and reloads the page), then the toast "Full re-analysis started".
enum StatsFullReanalysis {
    /// Starts the run. Returns the error to show, or nil when it started, was cancelled, or the lockout gate
    /// took over (09 R6: every error goes through `ServerSession.report`).
    static func start(in context: GameContext) async -> (any PresentableError)? {
        let client = context.client
        do {
            try await context.startJob(.analyze)
            context.toasts?.show(Labels.fullReanalysisStartedToast)
            return nil
        } catch {
            return context.session.report(error, from: client)
        }
    }

    /// The confirmation (game.js `fullRunConfirm`): the results stay on screen while it runs.
    static func confirmation(action: @escaping () -> Void) -> ConfirmationRequest {
        let text = Game.fullReanalysisConfirmation(showsResults: true)
        return ConfirmationRequest(title: text.title, message: text.message, confirmTitle: confirmTitle, isDestructive: false, action: action)
    }

    /// The confirming button (07 §13.16: a verb instead of the web's OK).
    static let confirmTitle = "Send to GPU"
}
