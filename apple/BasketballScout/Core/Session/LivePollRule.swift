import Foundation

/// How an open game page follows a live game (docs/LIVE.md "Data"): for most of the game its status is
/// `ready` with the LIVE job running, so "reload while processing" is not enough. While `live.state` is not
/// `ended` the page reads the game every `interval`; it loads the analysis again whenever
/// `live.analysisVersion` moved, and when the game has ended it stops and reloads the whole page once (the
/// film appears then).
nonisolated enum LivePollRule {
    /// The pause between two reads of a live game.
    static let interval: Duration = .seconds(10)

    /// What to do with a game that was just read.
    nonisolated enum Step: Hashable, Sendable {
        /// Still live, nothing new to load: show its counters.
        case update
        /// Still live, and the server has a newer analysis than the page shows: reload the page's data.
        case reloadAnalysis
        /// No longer live: stop following it and reload the whole page once.
        case ended
    }

    /// The page keeps reading `game`: it is live.
    static func shouldPoll(_ game: Game?) -> Bool {
        game?.isLive ?? false
    }

    /// - Parameters:
    ///   - loaded: the game as the server has it now.
    ///   - shownAnalysisVersion: the `live.analysisVersion` the analysis on the page was loaded at; nil when
    ///     the page shows no analysis (or one from before the game was live).
    static func step(loaded: Game, shownAnalysisVersion: Int?) -> Step {
        guard let live = loaded.live, live.isActive else { return .ended }
        if loaded.hasAnalysis, live.analysisVersion != shownAnalysisVersion { return .reloadAnalysis }
        return .update
    }
}
