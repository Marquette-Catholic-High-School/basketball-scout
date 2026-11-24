import Foundation

/// The header actions of the game page with their exact titles, enable rules and help texts (03 §7.4;
/// game.js:239-307): "Roster & jerseys", "Add film" / "Replace film", "Re-run analysis" / "Analyze film" and
/// "Full re-analysis".
nonisolated struct GameDetailActionState: Hashable, Sendable {
    /// The film and analysis actions are offered at all: not while the game is live (docs/LIVE.md: its film
    /// is arriving, and the server refuses new film and other analysis jobs until the stream has ended).
    var showsFilmAndAnalysisActions: Bool
    /// "Replace film" when the game has film (an upload or a link), else "Add film".
    var filmTitle: String
    /// What the re-run button starts: REANALYZE when the GPU results are saved, else ANALYZE (09 D1 #5).
    var rerunKind: JobKind
    /// "Re-run analysis" or "Analyze film".
    var rerunTitle: String
    /// Not busy, film or GPU results to work from, and nothing being started (03 §7.4, §8).
    var canRerun: Bool
    /// "An analysis is already running"; "Redo the stats on this server (about a minute, no GPU)"; or none.
    var rerunHelp: String?
    /// Film to send and GPU results a new run would replace.
    var showsFullReanalysis: Bool
    /// Not busy and nothing being started.
    var canFullReanalysis: Bool
    /// "An analysis is already running" or "Send the film to the GPU again".
    var fullReanalysisHelp: String

    /// - Parameters:
    ///   - isBusy: an analysis job is queued or running, by the game's status or the followed job
    ///     (`GameContext.isBusy`; game.js `showJobStatus` disables both buttons while a polled job is active).
    ///   - isStarting: a job is being started, retried or confirmed (the web disables the buttons on click).
    init(game: Game, isBusy: Bool, isStarting: Bool) {
        showsFilmAndAnalysisActions = game.offersFilmAndAnalysisActions
        filmTitle = game.filmButtonTitle
        rerunKind = game.rerunKind
        rerunTitle = game.rerunButtonTitle
        canRerun = game.canRerun && !isBusy && !isStarting
        rerunHelp = isBusy ? Game.analysisRunningHelp : game.rerunHelp
        showsFullReanalysis = game.showsFullReanalysis
        canFullReanalysis = game.showsFullReanalysis && !isBusy && !isStarting
        fullReanalysisHelp = isBusy ? Game.analysisRunningHelp : game.fullReanalysisHelp
    }

    /// The toast after the re-run button started its job (game.js:289).
    var rerunToast: String { rerunKind.startedToast }
}
