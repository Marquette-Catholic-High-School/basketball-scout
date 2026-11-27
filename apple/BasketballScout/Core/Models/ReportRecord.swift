import Foundation

/// A written scouting report (01 §4.7, 03 §1.6): `GET /api/games/{id}/reports` (all, newest first) and
/// `GET /api/reports/{id}`. A report job does not carry the id of the report it writes (09 R30).
///
/// The report text names minors: keep it in protected storage and out of logs (09 R44).
nonisolated struct ReportRecord: Codable, Hashable, Sendable, Identifiable {
    /// `r_` + 12 lowercase hex.
    var id: String
    var gameID: String
    var createdAt: Date?
    /// The Claude model that answered (may be a fallback model).
    var model: String
    /// Trimmed focus text, or null.
    var coachFocus: String?
    /// The structured report: render this natively (03 §5.3), not the Markdown.
    var report: ScoutingReport
    /// The Markdown rendered when the report was written (`export/report.md` re-renders it with the current
    /// game details, so the two can differ after a PATCH).
    var markdown: String
    /// Token counts: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.
    var usage: [String: Int]
    /// `end_turn` or `stop_sequence`; the web warns for a legacy `max_tokens`.
    var stopReason: String?
    /// The team the report is about; nil for reports written before "Report on" (they are on the scouted team).
    var side: TeamSide? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case gameID = "game_id"
        case createdAt = "created_at"
        case model
        case coachFocus = "coach_focus"
        case report
        case markdown
        case usage
        case stopReason = "stop_reason"
        case side
    }

    /// The team the report is about.
    var reportSide: TeamSide { side == .other ? .other : .scouted }

    /// The report hit the length limit (a legacy record; the current server fails such jobs instead, 03 §5.3).
    var wasCutOff: Bool { stopReason == "max_tokens" }
}
