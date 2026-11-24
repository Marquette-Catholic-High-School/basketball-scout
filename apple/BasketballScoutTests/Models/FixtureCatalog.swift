import Foundation
@testable import BasketballScout

/// One capture in `_manifest.json` (08 "Fixture index"): which request produced which fixture file.
nonisolated struct ManifestEntry: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let file: String?
    let method: String
    let endpoint: String
    let status: Int
    let query: JSONValue?
    let request: Request

    nonisolated struct Request: Decodable, Sendable {
        /// The JSON the capture sent (or `{"file": …, "bytes": …}` for raw bodies).
        let body: JSONValue?
    }

    var description: String { "\(method) \(endpoint) \(status) → \(file ?? "-")" }
}

/// The model each fixture decodes into: the 08 index's endpoint and status, mapped through 01 §4.10.
nonisolated enum FixtureModel: String, Sendable, CaseIterable {
    case game, games, job, jobs, uploadSession, filmResult, courtCalibration, courtLandmarks
    case gameRosters, roster, rosterImportResult, trackState, trackOverride, fastScoutNotes, tableNames
    case reportRecord, reportRecords, healthStatus, healthLive, gameAnalysis, openAPIDocument, errorEnvelope
    case liveStatus

    /// Every error status decodes as `ErrorEnvelope` (01 §2.1); success bodies by route.
    static func model(method: String, endpoint: String, status: Int) -> FixtureModel? {
        if status >= 400 { return .errorEnvelope }
        switch (method, endpoint) {
        case ("GET", "/api/health"): return .healthStatus
        case ("GET", "/api/health/live"): return .healthLive
        case ("GET", "/api/court/landmarks"): return .courtLandmarks
        case ("GET", "/api/openapi.json"): return .openAPIDocument
        case ("GET", "/api/games"): return .games
        case ("POST", "/api/games"), ("GET", "/api/games/{game_id}"), ("PATCH", "/api/games/{game_id}"): return .game
        case ("GET", "/api/games/{game_id}/analysis"), ("GET", "/api/games/{game_id}/export/analysis.json"): return .gameAnalysis
        case ("POST", "/api/games/{game_id}/uploads"), ("GET", "/api/uploads/{upload_id}"), ("PUT", "/api/uploads/{upload_id}/chunk"),
             ("POST", "/api/games/{game_id}/live/segments"):
            return .uploadSession
        // Live games (docs/LIVE.md).
        case ("POST", "/api/games/{game_id}/live"), ("GET", "/api/games/{game_id}/live"), ("POST", "/api/games/{game_id}/live/finish"):
            return .liveStatus
        case ("POST", "/api/uploads/{upload_id}/complete"), ("POST", "/api/games/{game_id}/video-url"): return .filmResult
        case ("POST", "/api/games/{game_id}/jobs"), ("GET", "/api/jobs/{job_id}"), ("POST", "/api/jobs/{job_id}/cancel"),
             ("POST", "/api/jobs/{job_id}/retry"), ("POST", "/api/games/{game_id}/reports"):
            return .job
        case ("GET", "/api/games/{game_id}/jobs"): return .jobs
        case ("PUT", "/api/games/{game_id}/calibration"): return .courtCalibration
        case ("GET", "/api/games/{game_id}/rosters"): return .gameRosters
        case ("GET", "/api/games/{game_id}/rosters/{side}"), ("PUT", "/api/games/{game_id}/rosters/{side}"),
             ("POST", "/api/games/{game_id}/rosters/{side}/players"),
             ("PATCH", "/api/games/{game_id}/rosters/{side}/players/{player_id}"),
             ("DELETE", "/api/games/{game_id}/rosters/{side}/players/{player_id}"):
            return .roster
        case ("POST", "/api/games/{game_id}/rosters/{side}/import"): return .rosterImportResult
        case ("GET", "/api/games/{game_id}/tracks"): return .trackState
        case ("PUT", "/api/games/{game_id}/tracks/{track_id}"): return .trackOverride
        case ("GET", "/api/games/{game_id}/export/fastscout-notes"): return .fastScoutNotes
        case ("GET", "/api/export/fastscout/tables"): return .tableNames
        case ("GET", "/api/games/{game_id}/reports"): return .reportRecords
        case ("GET", "/api/reports/{report_id}"): return .reportRecord
        default: return nil
        }
    }

    /// Decodes `data` as this model, encodes it with `ScoutJSON.encoder()` and decodes that again. Returns
    /// whether the second decode equals the first (a semantic round trip) and the decoded value's type name.
    func roundTrip(_ data: Data) throws -> (equal: Bool, typeName: String) {
        switch self {
        case .game: try Self.roundTrip(Game.self, data)
        case .games: try Self.roundTrip([Game].self, data)
        case .job: try Self.roundTrip(Job.self, data)
        case .jobs: try Self.roundTrip([Job].self, data)
        case .uploadSession: try Self.roundTrip(UploadSession.self, data)
        case .filmResult: try Self.roundTrip(FilmResult.self, data)
        case .courtCalibration: try Self.roundTrip(CourtCalibration.self, data)
        case .courtLandmarks: try Self.roundTrip(CourtLandmarks.self, data)
        case .gameRosters: try Self.roundTrip(GameRosters.self, data)
        case .roster: try Self.roundTrip(Roster.self, data)
        case .rosterImportResult: try Self.roundTrip(RosterImportResult.self, data)
        case .trackState: try Self.roundTrip(TrackState.self, data)
        case .trackOverride: try Self.roundTrip(TrackOverride.self, data)
        case .fastScoutNotes: try Self.roundTrip(FastScoutNotes.self, data)
        case .tableNames: try Self.roundTrip([String].self, data)
        case .reportRecord: try Self.roundTrip(ReportRecord.self, data)
        case .reportRecords: try Self.roundTrip([ReportRecord].self, data)
        case .healthStatus: try Self.roundTrip(HealthStatus.self, data)
        case .healthLive: try Self.roundTrip(HealthLive.self, data)
        case .gameAnalysis: try Self.roundTrip(GameAnalysis.self, data)
        case .openAPIDocument: try Self.roundTrip(JSONValue.self, data)
        case .errorEnvelope: try Self.roundTrip(ErrorEnvelope.self, data)
        case .liveStatus: try Self.roundTrip(LiveStatus.self, data)
        }
    }

    private static func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ data: Data) throws -> (equal: Bool, typeName: String) {
        let first = try ScoutJSON.decode(type, from: data)
        let second = try ScoutJSON.decode(type, from: ScoutJSON.encode(first))
        return (first == second, String(describing: type))
    }
}

/// The manifest and the fixture files, loaded once.
nonisolated enum FixtureCatalog {
    /// Every capture in `_manifest.json` (293: the 264 of 08 and 29 of a live game), or none if it cannot be read (a test checks it loads).
    static let manifest: [ManifestEntry] = (try? JSONDecoder().decode([ManifestEntry].self, from: Fixture.data("_manifest.json"))) ?? []

    /// Captures whose body is a JSON fixture.
    static let jsonEntries: [ManifestEntry] = manifest.filter { $0.file?.hasSuffix(".json") == true }

    /// The manifest entry of fixture `file`.
    static func entry(forFile file: String) -> ManifestEntry? {
        manifest.first { $0.file == file }
    }
}

/// Small helpers to look into raw fixture JSON.
nonisolated enum RawJSON {
    /// The object at `path` (string keys and int indexes) inside `root`.
    static func value(_ root: Any, at path: [any Sendable]) -> Any? {
        var node: Any? = root
        for step in path {
            if let key = step as? String {
                node = (node as? [String: Any])?[key]
            } else if let index = step as? Int, let array = node as? [Any], array.indices.contains(index) {
                node = array[index]
            } else {
                return nil
            }
        }
        return node
    }

    /// The keys of the object at `path`.
    static func keys(_ root: Any, at path: [any Sendable]) -> Set<String>? {
        (value(root, at: path) as? [String: Any]).map { Set($0.keys) }
    }

    /// A JSON object string → dictionary (for comparing encoded request bodies).
    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
