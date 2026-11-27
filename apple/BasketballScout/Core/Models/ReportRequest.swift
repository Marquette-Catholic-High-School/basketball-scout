import Foundation

/// Body of `POST /api/games/{id}/reports` → 202 `Job` of kind `report` (01 §4.7, 03 §5.1, 09 C1).
///
/// The server stores `coach_focus` untrimmed in `job.params`, so the client trims it and sends null when it
/// is empty (09 D1 #3); the initializer does both. ≤ 2000 characters (code points). The body must be a JSON
/// object: this always sends `{"coach_focus": …, "side": …}`.
///
/// `side` is the team the report is about ("Report on"). The analysis holds both teams, so a report on the
/// other team needs no new analysis.
nonisolated struct ReportRequest: Codable, Hashable, Sendable {
    var coachFocus: String?
    var side: TeamSide

    enum CodingKeys: String, CodingKey, CaseIterable {
        case coachFocus = "coach_focus"
        case side
    }

    /// The longest focus the server accepts (code points).
    static let maximumFocusLength = 2000

    /// Trims `coachFocus`; empty becomes nil.
    init(coachFocus: String? = nil, side: TeamSide = .scouted) {
        self.coachFocus = Self.normalizedFocus(coachFocus)
        self.side = side
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coachFocus = try container.decodeIfPresent(String.self, forKey: .coachFocus)
        side = try container.decodeIfPresent(TeamSide.self, forKey: .side) ?? .scouted
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coachFocus, forKey: .coachFocus)
        try container.encode(side, forKey: .side)
    }

    /// Trimmed focus text, nil when empty.
    static func normalizedFocus(_ text: String?) -> String? {
        FormText.trimmedOrNil(text)
    }

    /// The focus fits the server's limit (counted in Unicode code points, as pydantic does; 01 §1.4).
    var isFocusWithinLimit: Bool {
        (coachFocus?.unicodeScalars.count ?? 0) <= Self.maximumFocusLength
    }
}
