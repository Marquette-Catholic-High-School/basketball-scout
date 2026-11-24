import Foundation

// The web's label tables, kept in one place (09 R9). Text is the web's, word for word, with citations.
// Server strings themselves (`ErrorInfo`, `Job.message`, `TimelineEvent.label`, …) are shown verbatim and
// are not translated here. Derived states (what the web computes from a model) are in the `+Derived` files.

/// Label helpers that are not tied to one model type.
nonisolated enum Labels {
    /// En dash for an empty or unknown value (06 §13.2).
    static let emptyValue = "–"
    /// Middle dot with spaces, the web's separator for facts on one line (07 §5.5).
    static let separator = " · "

    /// A code with underscores shown as words: `left_wing_3` → "left wing 3" (timeline.js:29-31).
    static func humanize(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ")
    }

    /// A `Play.players` role (labels.js:96-106): "Ball handler", "Screener", "Post", …; unknown roles humanized.
    static func roleLabel(for role: String) -> String {
        switch role {
        case "ball_handler": "Ball handler"
        case "screener": "Screener"
        case "post_player": "Post"
        case "cutter": "Cutter"
        case "shooter": "Shooter"
        case "passer": "Passer"
        case "receiver": "Receiver"
        case "defender": "Defender"
        case "rebounder": "Rebounder"
        default: humanize(role)
        }
    }

    /// A shot subzone such as `restricted_area` → "restricted area" (the web humanizes it; 06 §8).
    static func subzoneLabel(_ subzone: String) -> String {
        humanize(subzone)
    }

    private static let landmarkParts: [String: String] = [
        "baseline_near_corner": "baseline, near corner",
        "baseline_far_corner": "baseline, far corner",
        "lane_baseline_near": "lane meets baseline (near side)",
        "lane_baseline_far": "lane meets baseline (far side)",
        "ft_line_near": "free-throw line, near elbow",
        "ft_line_far": "free-throw line, far elbow",
        "ft_circle_top": "top of the free-throw circle",
        "three_corner_near": "3-point line meets baseline (near corner)",
        "three_corner_far": "3-point line meets baseline (far corner)",
        "three_top": "top of the 3-point arc",
        "midcourt_near": "Half-court line at the near sideline",
        "midcourt_far": "Half-court line at the far sideline",
        "center": "Center of the court",
        "center_circle_near": "Center circle, near side",
        "center_circle_far": "Center circle, far side",
    ]

    /// A court landmark's friendly name (labels.js:192-216): "Left end: free-throw line, near elbow",
    /// "Center of the court"; unknown parts humanized.
    static func landmarkLabel(for name: String) -> String {
        let end: String?
        let key: String
        if name.hasPrefix("left_") {
            end = "Left end"
            key = String(name.dropFirst("left_".count))
        } else if name.hasPrefix("right_") {
            end = "Right end"
            key = String(name.dropFirst("right_".count))
        } else {
            end = nil
            key = name
        }
        let part = landmarkParts[key] ?? humanize(key)
        return end.map { "\($0): \(part)" } ?? part
    }

    /// `RosterImportResult.detected_columns` keys in the web's order (roster.js:21-24).
    static let importColumnOrder = [
        "jersey", "name", "first_name", "last_name", "position", "grade", "height", "notes", "fastscout_name",
    ]

    /// "Columns used" labels (roster.js:21-24); other keys (e.g. `suffix`) are shown raw.
    static func importColumnLabel(for key: String) -> String {
        switch key {
        case "jersey": "Jersey"
        case "name": "Name"
        case "first_name": "First name"
        case "last_name": "Last name"
        case "position": "Position"
        case "grade": "Grade"
        case "height": "Height"
        case "notes": "Notes"
        case "fastscout_name": "FastScout name"
        default: key
        }
    }

    /// "12 s ago", "10 min ago", "2 h ago", or "never" for nil (ui.js formatAgo; 07 §5.5). JavaScript's
    /// `Math.round` rounds halves up, as `.toNearestOrAwayFromZero` does for these non-negative values.
    static func ago(seconds: Double?) -> String {
        guard let seconds else { return "never" }
        if seconds < 90 { return "\(Int(seconds.rounded())) s ago" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min ago" }
        return "\(Int((seconds / 3600).rounded())) h ago"
    }
}

// MARK: - Teams

nonisolated extension TeamSide {
    /// Roster card heading and picker group (roster.js:9): "Scouted team" / "Their opponent in this film".
    var rosterTitle: String {
        switch self {
        case .scouted: "Scouted team"
        case .other: "Their opponent in this film"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }

    /// Short name for filters and when a team has no name (roster.html:62-63, game.js:59-65):
    /// "Scouted team" / "Opponent".
    var shortTitle: String {
        switch self {
        case .scouted: "Scouted team"
        case .other: "Opponent"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }

    /// The other team; nil for a side this app does not know.
    var opposite: TeamSide? {
        switch self {
        case .scouted: .other
        case .other: .scouted
        case .unknown: nil
        }
    }
}

// MARK: - Games

nonisolated extension GameStatus {
    /// Badge text (labels.js:108-115, 07 §3.5); an unknown status shows its raw value.
    var badgeText: String {
        switch self {
        case .draft: "No film"
        case .uploaded: "Film uploaded"
        case .queued: "Queued"
        case .processing: "Processing"
        case .ready: "Ready"
        case .failed: "Failed"
        case .unknown(let raw): raw
        }
    }

    /// Badge colour (07 §3.5): draft neutral, uploaded warning, queued/processing info, ready success,
    /// failed danger, anything else neutral.
    var badgeTone: StatusTone {
        switch self {
        case .draft: .neutral
        case .uploaded: .warning
        case .queued, .processing: .info
        case .ready: .success
        case .failed: .danger
        case .unknown: .neutral
        }
    }

    var badge: BadgeLabel { BadgeLabel(badgeText, tone: badgeTone) }

    /// An analysis job is queued or running (03 §4 "busy"; game.js:43): no other analysis can start.
    var isBusy: Bool { self == .queued || self == .processing }
}

// MARK: - Jobs

nonisolated extension JobKind {
    /// labels.js:128-132: "Film analysis", "Re-analysis", "Scouting report", "Live analysis"; "Job" for an
    /// unknown kind.
    var label: String {
        switch self {
        case .analyze: "Film analysis"
        case .reanalyze: "Re-analysis"
        case .report: "Scouting report"
        case .live: "Live analysis"
        case .unknown: "Job"
        }
    }

    /// The stages from which a cancel no longer stops a job of this kind (schemas.py:763-780
    /// `cancel_stops_job`, labels.js:135-144; 03 §3.3): ANALYZE and REANALYZE at `analyzing`/`reporting`,
    /// REPORT and LIVE at `reporting` (a live job stops at any earlier stage: the stats so far are kept).
    /// Such a job runs to the end; the cancel only skips a report not yet started.
    var tooLateToCancelStages: Set<JobStage> {
        switch self {
        case .analyze, .reanalyze: [.analyzing, .reporting]
        case .report, .live: [.reporting]
        case .unknown: []
        }
    }

    /// ANALYZE, REANALYZE or LIVE: the kinds that change the game's status and block each other.
    var isAnalysis: Bool { self == .analyze || self == .reanalyze || self == .live }

    /// The toast once a job of this kind was started (game.js:289; the game page, the calibration panel, the
    /// Data quality tab and the roster's re-run): "Re-running the analysis…" for REANALYZE, else "Analysis
    /// started".
    var startedToast: String {
        self == .reanalyze ? "Re-running the analysis\u{2026}" : "Analysis started"
    }
}

// MARK: - Toasts

nonisolated extension Labels {
    /// After a confirmed Full re-analysis started (game.js:306).
    static let fullReanalysisStartedToast = "Full re-analysis started"
    /// The coach confirmed the team the analysis already had as the scouted one (game.js:347).
    static let teamsConfirmedToast = "Thanks - teams confirmed."
}

nonisolated extension JobStatus {
    /// `queued` or `running` (`ACTIVE_JOB_STATUSES`, api.js:110-114).
    var isActive: Bool { self == .queued || self == .running }
}

nonisolated extension JobStage {
    /// The web's stage label (labels.js:117-126, 03 §3.2); "Working" for an unknown stage.
    var label: String {
        switch self {
        case .queued: "Waiting for the background worker"
        case .preparing: "Preparing the film"
        case .uploadingToGPU: "Uploading film to the GPU"
        case .gpuProcessing: "Analyzing on the GPU"
        case .downloadingResults: "Downloading results from the GPU"
        case .analyzing: "Building box score"
        case .reporting: "Writing scouting report"
        case .done: "Finished"
        case .unknown: "Working"
        }
    }
}

// MARK: - Analysis

nonisolated extension EventType {
    /// Filter label (labels.js:5-24); an unknown type humanized.
    var label: String {
        switch self {
        case .shotMade: "Made shot"
        case .shotMissed: "Missed shot"
        case .freeThrowMade: "Free throw made"
        case .freeThrowMissed: "Free throw missed"
        case .offensiveRebound: "Offensive rebound"
        case .defensiveRebound: "Defensive rebound"
        case .assist: "Assist"
        case .steal: "Steal"
        case .block: "Block"
        case .turnover: "Turnover"
        case .foul: "Foul"
        case .screen: "Screen"
        case .pass: "Pass"
        case .jumpBall: "Jump ball"
        case .periodStart: "Period start"
        case .periodEnd: "Period end"
        case .timeout: "Timeout"
        case .possessionChange: "Possession change"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }

    /// Marker and legend colour group (labels.js:27-46); unknown types are `.other`.
    var category: EventCategory {
        switch self {
        case .shotMade, .freeThrowMade: .make
        case .shotMissed, .freeThrowMissed: .miss
        case .offensiveRebound, .defensiveRebound: .rebound
        case .assist: .assist
        case .steal, .block: .defense
        case .turnover: .turnover
        case .foul: .foul
        case .jumpBall, .periodStart, .periodEnd, .timeout: .game
        case .screen, .pass, .possessionChange, .unknown: .other
        }
    }

    /// Left off the video marker strip (and its default markers) unless the coach filters for them:
    /// `pass`, `possession_change`, `screen` (labels.js:61). Also skipped by the video caption (06 §7.1).
    var isNoisy: Bool { self == .pass || self == .possessionChange || self == .screen }

    /// The word before the secondary player in the timeline's second line (timeline.js; 06 §8):
    /// shot made "ast.", shot missed "blk.", assist "to", steal "from", block "on", turnover "stolen by",
    /// foul "on", pass "to", screen "for", anything else "with".
    var secondaryPlayerPrefix: String {
        switch self {
        case .shotMade: "ast."
        case .shotMissed: "blk."
        case .assist: "to"
        case .steal: "from"
        case .block: "on"
        case .turnover: "stolen by"
        case .foul: "on"
        case .pass: "to"
        case .screen: "for"
        default: "with"
        }
    }

    /// A field goal or free throw row.
    var isShotOrFreeThrow: Bool {
        self == .shotMade || self == .shotMissed || self == .freeThrowMade || self == .freeThrowMissed
    }
}

nonisolated extension ShotZone {
    /// labels.js:88-93: "Paint", "Mid-range", "3-point", "Unknown"; a zone this app does not know humanized.
    var label: String {
        switch self {
        case .paint: "Paint"
        case .mid: "Mid-range"
        case .three: "3-point"
        case .unknownZone: "Unknown"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }

    /// Row label in the shot chart's zone table (06 §10.2): "Unknown zone" for shots without a location.
    var zoneTableLabel: String { self == .unknownZone ? "Unknown zone" : label }

    /// Column header in the box score's "Shooting by zone" table (06 §9): "No location" for that column.
    var boxScoreColumnLabel: String { self == .unknownZone ? "No location" : label }
}

nonisolated extension PlayType {
    /// labels.js:63-77 (= schemas.py:347-361): "Pick & Roll", …, "Full-Court Press"; unknown humanized.
    var label: String {
        switch self {
        case .pickAndRoll: "Pick & Roll"
        case .pickAndPop: "Pick & Pop"
        case .isolation: "Isolation"
        case .fastBreak: "Fast Break"
        case .postUp: "Post-Up"
        case .handoff: "Dribble Handoff"
        case .offBallScreen: "Off-Ball Screen"
        case .spotUp: "Spot-Up"
        case .cut: "Cut"
        case .putback: "Putback"
        case .manDefense: "Man-to-Man Defense"
        case .zoneDefense: "Zone Defense"
        case .press: "Full-Court Press"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }

    /// Offense or defense (schemas.py:331-345); nil for a type this app does not know (use `Play.category`).
    var category: PlayCategory? {
        switch self {
        case .manDefense, .zoneDefense, .press: .defense
        case .unknown: nil
        default: .offense
        }
    }
}

nonisolated extension PlayCategory {
    /// "Offense" / "Defense" (the plays tab's table headings, 06 §11).
    var label: String {
        switch self {
        case .offense: "Offense"
        case .defense: "Defense"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }
}

nonisolated extension PlayOutcome {
    /// labels.js:79-86: "Made FG", "Missed FG", "Turnover", "Foul", "No shot", and "–" for unknown.
    var label: String {
        switch self {
        case .madeFieldGoal: "Made FG"
        case .missedFieldGoal: "Missed FG"
        case .turnover: "Turnover"
        case .foul: "Foul"
        case .noShot: "No shot"
        case .unknownOutcome: Labels.emptyValue
        case .unknown(let raw): Labels.humanize(raw)
        }
    }
}

nonisolated extension PossessionOutcome {
    /// The possessions list's outcome (the web shows no possessions; app wording): the play outcome's label
    /// where the values are shared ("Made FG", "Missed FG", "Turnover", "Foul", "–" for unknown), else the
    /// value in words with a capital ("Free throws", "End of period").
    var label: String {
        let shared = PlayOutcome(rawValue: rawValue)
        if shared.isKnown { return shared.label }
        let words = Labels.humanize(rawValue)
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

nonisolated extension WarningSeverity {
    /// Notice colour (quality.js:6, 72): info, warning, error → danger; unknown severities as warnings.
    var tone: StatusTone {
        switch self {
        case .info: .info
        case .warning: .warning
        case .error: .danger
        case .unknown: .warning
        }
    }
}

nonisolated extension CoordMode {
    /// Data quality "Coordinates" fact (06 §12): "Court feet" / "Video pixels only".
    var label: String {
        switch self {
        case .court: "Court feet"
        case .pixel: "Video pixels only"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }
}

nonisolated extension ThreatLevel {
    /// "High" / "Medium" / "Low" (the server's Markdown capitalises it the same way, 03 §5.2).
    var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unknown(let raw): raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Badge colour (03 §5.3): High red, Medium amber, Low green.
    var tone: StatusTone {
        switch self {
        case .high: .danger
        case .medium: .warning
        case .low: .success
        case .unknown: .neutral
        }
    }
}

// MARK: - Rosters, tracks, media, health

nonisolated extension TrackMethod {
    /// The tracks table's "How" column (roster.js:25-27): "Exact read", "Close read", "Partial read",
    /// "Set by you", "Not on roster", "No readable jersey"; an unknown method raw (as the web).
    var label: String {
        switch self {
        case .exact: "Exact read"
        case .fuzzy: "Close read"
        case .partial: "Partial read"
        case .manual: "Set by you"
        case .unrostered: "Not on roster"
        case .noReads: "No readable jersey"
        case .unknown(let raw): raw
        }
    }
}

nonisolated extension RosterImportMode {
    /// The import radio buttons (05 §7.3): "Replace this roster" / "Merge (update matching jerseys)".
    var label: String {
        switch self {
        case .replace: "Replace this roster"
        case .merge: "Merge (update matching jerseys)"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }
}

nonisolated extension VideoVariant {
    /// The player's toggle (06 §7.3): "Annotated" / "Original".
    var label: String {
        switch self {
        case .original: "Original"
        case .annotated: "Annotated"
        case .unknown(let raw): Labels.humanize(raw)
        }
    }
}

nonisolated extension HealthState {
    /// The system status "Overall" row (07 §3.8): "OK" / "Needs attention".
    var label: String { self == .ok ? "OK" : "Needs attention" }
}

nonisolated extension CourtCalibration {
    /// The web's verdict on `reprojection_error_ft` (calibrate.js:14-19): ≤ 1 ft "Excellent fit",
    /// ≤ 2.5 "Good fit", ≤ 5 "Fair fit - double-check the points", else "Poor fit - some points are probably
    /// on the wrong landmark".
    var fitQuality: BadgeLabel {
        let error = reprojectionErrorFt
        if error <= 1 { return BadgeLabel("Excellent fit", tone: .success) }
        if error <= 2.5 { return BadgeLabel("Good fit", tone: .success) }
        if error <= 5 { return BadgeLabel("Fair fit - double-check the points", tone: .warning) }
        return BadgeLabel("Poor fit - some points are probably on the wrong landmark", tone: .danger)
    }
}
