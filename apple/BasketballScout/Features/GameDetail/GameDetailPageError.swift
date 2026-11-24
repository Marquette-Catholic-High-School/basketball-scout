import Foundation

/// What the page error area under the header shows (03 §7.3 row 2, 07 §5.1): one error box at a time, the
/// newest problem.
enum GameDetailPageError {
    /// The game (or its analysis) could not be loaded: "Try again" when retrying can help, and "Back to games"
    /// when there is no game to show (03 §7.3 step 1).
    case load(any PresentableError, canGoBack: Bool)
    /// Starting a job or confirming the teams failed (game.js `startJob` / `confirmTeam`).
    case action(any PresentableError)

    var error: any PresentableError {
        switch self {
        case .load(let error, _), .action(let error): error
        }
    }
}

/// What the page looked like when an action failed. The web clears its page error area with the next
/// refresh that loads the game; here the box stays until the page has visibly moved on (the game, its
/// status or the job panel's job changed), a newer load problem replaced it, or the coach acts again.
nonisolated struct GameDetailStateKey: Hashable, Sendable {
    var gameUpdatedAt: Date?
    var gameStatus: GameStatus?
    var jobID: String?
    var jobIsActive: Bool
    /// The load problem shown at the time (a different one is newer and replaces the action's box).
    var loadProblem: String?

    init(game: Game?, latestAnalysisJob: Job?, loadError: (any PresentableError)?) {
        gameUpdatedAt = game?.updatedAt
        gameStatus = game?.status
        jobID = latestAnalysisJob?.id
        jobIsActive = latestAnalysisJob?.isActive ?? false
        loadProblem = loadError.map { $0.title + "\n" + $0.message }
    }
}
