import Foundation

// What the web computes from a game (03 §4 "Derived states", §7.1–§7.7; game.js, index.js).

nonisolated extension Game {
    /// Film the GPU can analyse: an uploaded file or a video link (`hasFilm`, game.js:38).
    var hasFilm: Bool { hasVideo || videoURL != nil }

    /// An analysis job is queued or running (03 §4 "busy"): no other analysis, upload or link can start.
    var isBusy: Bool { status.isBusy }

    /// Something can be played here: the stored film or the GPU's annotated copy (03 §4 `playable`).
    var isPlayable: Bool { hasVideo || hasAnnotatedVideo }

    /// What "Re-run" starts (03 §4 `rerunKind`, 09 D1 #5): REANALYZE when the GPU results are saved,
    /// else ANALYZE.
    var rerunKind: JobKind { hasTracking ? .reanalyze : .analyze }

    /// The header's re-run button (03 §7.4): "Re-run analysis" when the GPU results are saved, else "Analyze film".
    var rerunButtonTitle: String { hasTracking ? "Re-run analysis" : "Analyze film" }

    /// The re-run button is enabled (03 §7.4): not busy, not live, and film or GPU results to work from. Also
    /// disable it while a polled analysis job is active.
    var canRerun: Bool { !isBusy && !isLive && (hasFilm || hasTracking) }

    /// The header offers "Add film" / "Replace film", "Re-run analysis" / "Analyze film" and "Full
    /// re-analysis": not while the game is live (the server refuses all three with a 409, docs/LIVE.md).
    var offersFilmAndAnalysisActions: Bool { !isLive }

    /// The re-run button's help text (game.js:262): busy → "An analysis is already running"; REANALYZE →
    /// "Redo the stats on this server (about a minute, no GPU)"; else none.
    var rerunHelp: String? {
        if isBusy { return Self.analysisRunningHelp }
        return hasTracking ? "Redo the stats on this server (about a minute, no GPU)" : nil
    }

    /// "Full re-analysis" is offered (03 §7.4): film to send and GPU results that a new run would replace.
    /// Enabled when not busy.
    var showsFullReanalysis: Bool { hasFilm && hasTracking && !isLive }

    /// The Full re-analysis button's help text (game.js:266-267).
    var fullReanalysisHelp: String { isBusy ? Self.analysisRunningHelp : "Send the film to the GPU again" }

    /// Help text of analysis buttons while one runs.
    static let analysisRunningHelp = "An analysis is already running"

    /// The film button (03 §7.4): "Replace film" when there is film, else "Add film".
    var filmButtonTitle: String { hasFilm ? "Replace film" : "Add film" }

    /// The games list's status badge (07 §3.5); "Live" while the game is live.
    var statusBadge: BadgeLabel { liveBadge ?? status.badge }

    /// The games list's small line under an error badge: message and hint joined by a space (index.js:73-75).
    var errorSummary: String? {
        guard let error else { return nil }
        return [error.message, error.hint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The pipeline team id → side map as integers (keys that are not integers are skipped).
    var teamIDsBySide: [Int: TeamSide] {
        Dictionary(teamIDMap.compactMap { key, side in Int(key).map { ($0, side) } }, uniquingKeysWith: { first, _ in first })
    }

    /// A team's name as the game page shows it (game.js:59-65): the analysis's name, else the game's, else
    /// "Scouted team" / "Opponent" (empty names fall through).
    func teamName(_ side: TeamSide, analysis: GameAnalysis? = nil) -> String {
        if let name = analysis?.team(side)?.name, !name.isEmpty { return name }
        switch side {
        case .scouted where !scoutedTeam.isEmpty: return scoutedTeam
        case .other where !otherTeam.isEmpty: return otherTeam
        default: return side.shortTitle
        }
    }

    /// The "No film yet" card (03 §7.3 row 5): no stored film, no link and no analysis on screen. Not for a
    /// live game, whose film is on its way (`pendingNotice` says so).
    func showsNoFilmCard(hasAnalysis: Bool) -> Bool {
        !hasVideo && videoURL == nil && !hasAnalysis && !isLive
    }

    /// The "No film yet" card's text (03 §7.3).
    static let noFilmMessage = "Upload the game film (MP4) or give a direct video link to start the analysis."

    /// The notice while there is film but no analysis on screen (03 §7.7, game.js:200-227), or while a live
    /// game waits for its first stats; nil otherwise.
    ///
    /// - Parameters:
    ///   - hasAnalysis: an analysis is shown.
    ///   - latestAnalysisJob: the job panel's job, which picks the "about a minute" hint for a REANALYZE.
    ///   - jobPanelVisible: a failed game shows its own error only when the job panel does not.
    func pendingNotice(hasAnalysis: Bool, latestAnalysisJob: Job?, jobPanelVisible: Bool) -> PendingNotice? {
        // A live game has no film yet; until its first part is analysed there are no stats either.
        if isLive, !hasAnalysis { return .info(Self.liveWaitingNotice) }
        guard hasFilm, !hasAnalysis else { return nil }
        if status == .failed, let error, !jobPanelVisible { return .error(error) }
        switch status {
        case .queued, .processing:
            return .info(NoticeText(
                tone: .info,
                message: "Results will appear here when the analysis finishes.",
                hint: latestAnalysisJob?.kind == .reanalyze
                    ? "Re-run analysis takes about a minute on this server."
                    : "Long games can take 30-60 minutes on the GPU."))
        case .failed:
            return .info(NoticeText(
                tone: .info,
                message: "There are no results because the analysis failed.",
                hint: "See the error above and run the analysis again once the problem is fixed."))
        case .ready:
            return .info(NoticeText(
                tone: .info,
                message: "The analysis could not be loaded.",
                hint: "Reload the page; if it keeps happening, re-run the analysis."))
        default:
            return .info(hasTracking
                ? NoticeText(
                    tone: .info,
                    message: "The GPU results for this film are saved, but the stats have not been built from them yet.",
                    hint: "Click Re-run analysis to build them on this server (about a minute, no GPU).")
                : NoticeText(
                    tone: .info,
                    message: "This film hasn't been analyzed yet.",
                    hint: "Click Analyze film to send it to the GPU."))
        }
    }

    /// The "Film not available" notice (03 §7.7, game.js:186-197): an analysis is shown but nothing can be
    /// played; nil otherwise. Offer "Upload the film" with it, except while the game is live: its film is put
    /// together when the stream ends (docs/LIVE.md), and the server takes no other film until then.
    func filmUnavailableNotice(hasAnalysis: Bool) -> NoticeText? {
        guard hasAnalysis, !isPlayable else { return nil }
        if isLive { return Self.liveFilmNotice }
        let why = videoURL != nil
            ? "It was analyzed from a video link and isn't stored on this server"
            : "The film isn't stored on this server"
        return NoticeText(tone: .info, title: "Film not available", message: "\(why), so it can't be played here. The stats below still work.")
    }

    /// The Full re-analysis confirmation (03 §7.4, game.js:25-30); also asked before Start again / Retry of a
    /// job that would go back to the GPU while `has_tracking` (03 §7.5). `showsResults`: an analysis is on
    /// screen (adds "The current results stay on this page until it finishes.").
    static func fullReanalysisConfirmation(showsResults: Bool) -> ConfirmationText {
        let cost = "A full re-analysis takes about as long as the first run and costs another GPU run."
            + (showsResults ? " The current results stay on this page until it finishes." : "")
        return ConfirmationText(
            title: "Send the film to the GPU again?",
            message: cost + "\n\n"
                + "It numbers the players' tracks again, so it clears the track assignments you made on the Roster page; redo them afterwards.\n\n"
                + "(Re-run analysis only redoes the stats on this server.)")
    }

    /// The delete confirmation (03 §7.1, 07 §3.7). The server deletes everything; there is no undo.
    var deleteConfirmation: ConfirmationText {
        ConfirmationText(
            title: "Delete \"\(displayTitle)\"?",
            message: "This removes the film, analysis, rosters and reports for this game. It cannot be undone.")
    }
}

/// The game page's notice while there is film but no analysis (03 §7.7).
nonisolated enum PendingNotice: Hashable, Sendable {
    /// Show `Game.error` as an error box.
    case error(ErrorInfo)
    /// Show an info notice.
    case info(NoticeText)
}
