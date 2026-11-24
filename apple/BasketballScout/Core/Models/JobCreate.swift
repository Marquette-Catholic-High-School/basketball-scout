import Foundation

/// Body of `POST /api/games/{id}/jobs` → 201 `Job` (01 §4.3, 03 §1.5).
///
/// `params` must be an object (never null). For `report` the server keeps only `coach_focus` (≤ 2000
/// characters or null); for the other kinds a `coach_focus`, if present, is checked the same way. The web
/// sends `{"kind":"analyze"}` / `{"kind":"reanalyze"}`, so empty `params` are left out.
nonisolated struct JobCreate: Codable, Hashable, Sendable {
    var kind: JobKind
    var params: [String: JSONValue]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case params
    }

    init(kind: JobKind, params: [String: JSONValue] = [:]) {
        self.kind = kind
        self.params = params
    }

    /// `{"kind":"analyze"}`: send the film to the GPU (needs film; 409 `VIDEO_MISSING` otherwise).
    static let analyze = JobCreate(kind: .analyze)
    /// `{"kind":"reanalyze"}`: rebuild the stats from the stored GPU results (needs `has_tracking`).
    static let reanalyze = JobCreate(kind: .reanalyze)

    /// A report job with the coach's focus, trimmed and null when empty (09 D1 #3). Same as
    /// `POST /api/games/{id}/reports` except for the status code (201 here, 202 there; 09 C1).
    static func report(coachFocus: String?) -> JobCreate {
        JobCreate(kind: .report, params: ["coach_focus": ReportRequest.normalizedFocus(coachFocus).map(JSONValue.string) ?? .null])
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(JobKind.self, forKey: .kind)
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if !params.isEmpty { try container.encode(params, forKey: .params) }
    }
}
