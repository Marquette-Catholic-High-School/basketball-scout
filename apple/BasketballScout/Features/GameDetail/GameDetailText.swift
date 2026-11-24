import Foundation

/// The game page's own texts that the models do not hold (03 §7.3–§7.6, 07 §5.2–§5.4; game.js, jobpanel.js):
/// the job panel footer, the team banner and the verbs on confirmation buttons. Every other text on the page
/// comes from `Labels.swift` and the models' `+Derived` files (stage labels, cancel questions, notices, the
/// Full re-analysis confirmation, the job-start toasts).
nonisolated enum GameDetailText {
    // MARK: Header (game.html:29-32)

    static let roster = "Roster & jerseys"
    static let fullReanalysis = "Full re-analysis"
    static let refresh = "Refresh"
    /// The page title before the game is loaded (07 §1.1: "Loading game…").
    static let loadingGame = "Loading game\u{2026}"
    /// The window title while there is no game to name.
    static let untitled = "Game"

    // MARK: Job panel (jobpanel.js)

    /// The active panel's last line (jobpanel.js:121, "You can close this page; …", in the app's words).
    static let jobPanelFooter = "You can leave this screen or close the app; processing continues on the server."
    /// After following the job gave up (07 §5.1).
    static let checkAgain = "Check again"
    /// Busy label of Start again / Retry / Re-run analysis (07 §5.4).
    static let starting = "Starting\u{2026}"
    /// The progress bar's spoken name (07 §8).
    static let analysisProgress = "Analysis progress"

    // MARK: Team banner (game.js:309-356, 06 §5.3)

    /// "Which team is <scouted_team>?" (the game's own scouted team name).
    static func teamBannerTitle(scoutedTeam: String) -> String {
        "Which team is \(scoutedTeam)?"
    }

    static let teamBannerHint =
        "The analysis split the players by jersey colour. Pick the colour the scouted team wears in this film so every stat goes to the right team."
    /// Busy label of the jersey-colour buttons (07 §5.4).
    static let saving = "Saving\u{2026}"

    // MARK: Film (03 §7.3 row 5, §7.7; 04 §6.2)

    static let noFilmTitle = "No film yet"
    static let addFilm = "Add film"
    /// The button of the "Film not available" notice (game.js:196).
    static let uploadTheFilm = "Upload the film"
    /// A film upload of this game running on this device (app-only: the web cannot leave a running upload).
    static let filmUpload = "Film upload"
    static let showUpload = "Show upload"
    static let uploadProgress = "Upload progress"
    /// The analysis on the page is the cached copy because the server's could not be loaded (09 R28).
    static let cachedAnalysis = "Showing the analysis saved on this device; the latest copy could not be loaded."

    // MARK: Page error area (03 §7.3 step 1, 07 §5.1)

    static let tryAgain = "Try again"
    static let backToGames = "Back to games"

    // MARK: Confirmation buttons (07 §13.16: verbs instead of the browser's OK / Cancel)

    /// Confirms a Full re-analysis, or a Start again / Retry that sends the film to the GPU again.
    static let sendToGPU = "Send to GPU"
    /// Confirms a cancel that still stops the job.
    static let stopJob = "Stop job"
    /// Confirms a cancel that comes too late to stop the job (it only skips a report not yet started).
    static let cancelAnyway = "Cancel anyway"
    /// Leaves the job running.
    static let keepRunning = "Keep running"
}
