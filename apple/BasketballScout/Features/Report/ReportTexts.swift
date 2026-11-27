import Foundation

/// The web's wording for the scouting report tab that the shared label tables do not cover
/// (`scout/static/js/report.js`, `game.html:245-266`; 03 §5.3, §7.8; 09 B13). Job stage texts, cancel
/// questions and kind labels come from `Job+Derived` / `Labels`; server text is never here (it is shown
/// verbatim). Native-only wording (copy, share, save) is American English in the web's tone (07 §12).
nonisolated enum ReportTexts {
    // MARK: Top row and controls (03 §7.8)

    static let tabTitle = "Scouting report"
    static let versionLabel = "Version"
    /// Appended to a version that was written with a coach focus.
    static let withCoachFocus = "with coach focus"
    static let downloadMarkdown = "Download .md"
    static let print = "Print"

    /// Shown when `health.claude_configured == false`; Generate stays enabled (the server answers 503).
    static let claudeNotConfigured = NoticeText(
        tone: .warning,
        title: "Claude is not configured",
        message: "Scouting reports need an Anthropic API key.",
        hint: "Add ANTHROPIC_API_KEY to .env on the server and restart the worker. Stats and exports work without it.")

    static let sideLabel = "Report on"
    static let sideHint = "Both teams are in the analysis, so a report on the other team needs no new analysis."
    static let focusLabel = "Coach focus (optional)"
    static let focusPlaceholder = "For example: we play a 2-3 zone - how will they attack it? Who do we leave open?"

    static let generate = "Generate report"
    static let regenerate = "Regenerate report"

    /// The status line's tail while a report job is followed: "<stage label>… This usually takes one to
    /// three minutes." (report.js:160).
    static let usualDuration = "This usually takes one to three minutes."
    /// The tail after a cancel that came too late (report.js:162).
    static let lateCancelNote = "Cancel requested: Claude is already writing it, so it will finish and be kept."

    /// The body without a report on the chosen team.
    static func noReportYet(team: String) -> String {
        "No scouting report on \(team) yet. Add anything you want Claude to focus on, then click Generate report."
    }

    // MARK: Finished report jobs (report.js:166-177, 09 B13)

    static let cancelledMessage = "Report generation was cancelled."
    /// A failed report job without `error` (09 B13).
    static let failedTitle = "Report failed"
    static let failedMessage = "The report could not be written."

    // MARK: The report (03 §5.3)

    static func heading(gameTitle: String) -> String { "Scouting report: \(gameTitle)" }
    static func written(date: String, model: String) -> String {
        date.isEmpty ? "Written by \(model)" : "Written \(date) by \(model)"
    }
    static func coachFocus(_ focus: String) -> String { "Coach focus: \(focus)" }

    /// A legacy record that hit the length limit (`stop_reason == "max_tokens"`).
    static let cutOff = NoticeText(
        tone: .warning,
        title: "This report was cut off",
        message: "It hit the length limit before finishing.",
        hint: "Raise SCOUT_CLAUDE_MAX_TOKENS in .env and regenerate.")

    /// Key players table headers (report.js:33).
    static let keyPlayerColumns = ["#", "Player", "Role", "Threat", "Strengths", "Weaknesses", "How to defend"]
    /// Play tendencies table headers (report.js:49).
    static let tendencyColumns = ["Play type", "Frequency", "Effectiveness", "How to counter"]

    // MARK: Native additions

    static let copyAsText = "Copy as Text"
    static let share = "Share…"
    static let printEllipsis = "Print…"
    static let shareAndExport = "Share and export"
    static let reportCopied = "Scouting report copied"
    static let cancelReport = "Cancel"
    /// The confirm buttons of the report Cancel (09 R31): the question is `Job.cancelQuestion`.
    static let stopReportConfirm = "Stop the report"
    static let keepWriting = "Keep it"
    static let loadingReports = "Loading reports…"
    static let printUnavailable = "Printing isn't available on this device."
}
