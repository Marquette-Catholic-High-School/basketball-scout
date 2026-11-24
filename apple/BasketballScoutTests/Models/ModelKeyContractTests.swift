import Foundation
import Testing
@testable import BasketballScout

/// Each model's `CodingKeys` are exactly the JSON keys the server sends (01 §1.2: every key is always
/// present), checked against a real fixture object, and the key counts match 09's table.
nonisolated struct ModelKeyContractTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let model: String
        let keys: [String]
        let fixture: String
        let path: [any Sendable]
        /// Keys the model has that this fixture's server did not send yet (it is older than live games).
        var newer: Set<String> = []

        var testDescription: String { model }
    }

    /// What live games added (docs/LIVE.md): a server older than them sends none of these keys.
    static let liveGameKeys: Set<String> = ["live"]
    static let liveUploadKeys: Set<String> = ["live_segment", "live_duration_s"]

    static func keys<K: CodingKey & CaseIterable>(_ type: K.Type) -> [String] {
        type.allCases.map(\.stringValue)
    }

    static let cases: [Case] = [
        Case(model: "Game", keys: keys(Game.CodingKeys.self), fixture: "game_get.json", path: [], newer: liveGameKeys),
        Case(model: "Game (failed)", keys: keys(Game.CodingKeys.self), fixture: "game_failed.json", path: [], newer: liveGameKeys),
        Case(model: "Game (live)", keys: keys(Game.CodingKeys.self), fixture: "live_game_capturing.json", path: []),
        Case(model: "LiveInfo", keys: keys(LiveInfo.CodingKeys.self), fixture: "live_game_capturing.json", path: ["live"]),
        Case(model: "LiveStatus", keys: keys(LiveStatus.CodingKeys.self), fixture: "live_status_capturing.json", path: []),
        Case(model: "LiveSegment", keys: keys(LiveSegment.CodingKeys.self), fixture: "live_status_capturing.json", path: ["segments", 0]),
        Case(model: "Job (live)", keys: keys(Job.CodingKeys.self), fixture: "live_job_running.json", path: []),
        Case(model: "UploadSession (live part)", keys: keys(UploadSession.CodingKeys.self), fixture: "live_segment_create.json", path: []),
        Case(model: "ErrorInfo", keys: keys(ErrorInfo.CodingKeys.self), fixture: "game_failed.json", path: ["error"]),
        Case(model: "CourtCalibration", keys: keys(CourtCalibration.CodingKeys.self), fixture: "calibration_put.json", path: []),
        Case(model: "CalibrationPoint", keys: keys(CalibrationPoint.CodingKeys.self), fixture: "calibration_put.json", path: ["points", 0]),
        Case(model: "Job", keys: keys(Job.CodingKeys.self), fixture: "job_get.json", path: []),
        Case(model: "UploadSession", keys: keys(UploadSession.CodingKeys.self), fixture: "upload_create.json", path: [], newer: liveUploadKeys),
        Case(model: "FilmResult", keys: keys(FilmResult.CodingKeys.self), fixture: "upload_complete.json", path: []),
        Case(model: "ErrorEnvelope (with upload)", keys: keys(ErrorEnvelope.CodingKeys.self), fixture: "err_409_chunk_wrong_offset.json", path: []),
        Case(model: "HealthStatus", keys: keys(HealthStatus.CodingKeys.self), fixture: "health.json", path: []),
        Case(model: "HealthLive", keys: keys(HealthLive.CodingKeys.self), fixture: "health_live.json", path: []),
        Case(model: "CourtLandmarks", keys: keys(CourtLandmarks.CodingKeys.self), fixture: "court_landmarks.json", path: []),
        Case(model: "CourtDimensions", keys: keys(CourtDimensions.CodingKeys.self), fixture: "court_landmarks.json", path: ["court"]),
        Case(model: "GameRosters", keys: keys(GameRosters.CodingKeys.self), fixture: "rosters_get.json", path: []),
        Case(model: "Roster", keys: keys(Roster.CodingKeys.self), fixture: "roster_get_other.json", path: []),
        Case(model: "RosterPlayer", keys: keys(RosterPlayer.CodingKeys.self), fixture: "roster_get_other.json", path: ["players", 0]),
        Case(model: "RosterImportResult", keys: keys(RosterImportResult.CodingKeys.self), fixture: "roster_import.json", path: []),
        Case(model: "TrackState", keys: keys(TrackState.CodingKeys.self), fixture: "tracks.json", path: []),
        Case(model: "TrackAssignment", keys: keys(TrackAssignment.CodingKeys.self), fixture: "tracks.json", path: ["assignments", 0]),
        Case(model: "TrackOverride", keys: keys(TrackOverride.CodingKeys.self), fixture: "track_override_assign.json", path: []),
        Case(model: "ReportRecord", keys: keys(ReportRecord.CodingKeys.self), fixture: "report_get_seeded.json", path: []),
        Case(model: "ScoutingReport", keys: keys(ScoutingReport.CodingKeys.self), fixture: "report_get_seeded.json", path: ["report"]),
        Case(model: "KeyPlayer", keys: keys(KeyPlayer.CodingKeys.self), fixture: "report_get_seeded.json", path: ["report", "key_players", 0]),
        Case(model: "PlayTendency", keys: keys(PlayTendency.CodingKeys.self), fixture: "report_get_seeded.json", path: ["report", "play_tendencies", 0]),
        Case(model: "FastScoutNotes", keys: keys(FastScoutNotes.CodingKeys.self), fixture: "export_fastscout_notes.json", path: []),
        Case(model: "GameAnalysis", keys: keys(GameAnalysis.CodingKeys.self), fixture: "analysis.json", path: []),
        Case(model: "VideoInfo", keys: keys(VideoInfo.CodingKeys.self), fixture: "analysis.json", path: ["video"]),
        Case(model: "PipelineInfo", keys: keys(PipelineInfo.CodingKeys.self), fixture: "analysis.json", path: ["pipeline"]),
        Case(model: "TeamSummary", keys: keys(TeamSummary.CodingKeys.self), fixture: "analysis.json", path: ["teams", 0]),
        Case(model: "TimelineEvent", keys: keys(TimelineEvent.CodingKeys.self), fixture: "analysis.json", path: ["timeline", 0]),
        Case(model: "PlayerRef", keys: keys(PlayerRef.CodingKeys.self), fixture: "analysis.json", path: ["shots", 0, "player"]),
        Case(model: "Possession", keys: keys(Possession.CodingKeys.self), fixture: "analysis.json", path: ["possessions", 0]),
        Case(model: "Play", keys: keys(Play.CodingKeys.self), fixture: "analysis.json", path: ["plays", 0]),
        Case(model: "ShotRecord", keys: keys(ShotRecord.CodingKeys.self), fixture: "analysis.json", path: ["shots", 0]),
        Case(model: "TeamBoxScore", keys: keys(TeamBoxScore.CodingKeys.self), fixture: "analysis.json", path: ["box_scores", 0]),
        Case(model: "BoxScoreLine", keys: keys(BoxScoreLine.CodingKeys.self), fixture: "analysis.json", path: ["box_scores", 0, "totals"]),
        Case(model: "ZoneSplits", keys: keys(ZoneSplits.CodingKeys.self), fixture: "analysis.json", path: ["box_scores", 0, "totals", "zones"]),
        Case(model: "ShootingSplit", keys: keys(ShootingSplit.CodingKeys.self), fixture: "analysis.json", path: ["box_scores", 0, "totals", "zones", "paint"]),
        Case(model: "PlayTypeSummary", keys: keys(PlayTypeSummary.CodingKeys.self), fixture: "analysis.json", path: ["play_summary", 0]),
        Case(model: "DataQuality", keys: keys(DataQuality.CodingKeys.self), fixture: "analysis.json", path: ["data_quality"]),
        Case(model: "PipelineWarning", keys: keys(PipelineWarning.CodingKeys.self), fixture: "analysis_unmatched.json", path: ["data_quality", "warnings", 0]),
    ]

    @Test(arguments: cases)
    func codingKeysMatchTheFixture(_ testCase: Case) throws {
        let root = try Fixture.jsonObject(testCase.fixture)
        let fixtureKeys = try #require(RawJSON.keys(root, at: testCase.path), "no object at \(testCase.path)")
        #expect(Set(testCase.keys).subtracting(testCase.newer) == fixtureKeys)
        #expect(testCase.newer.isSubset(of: Set(testCase.keys)))
        #expect(testCase.keys.count == Set(testCase.keys).count, "duplicate JSON keys")
    }

    /// 09 "Checks that passed": key counts per model, plus what live games added (`Game.live`,
    /// `UploadSession.live_segment` and `.live_duration_s`).
    @Test func keyCountsMatchSpec09() {
        #expect(Self.keys(Game.CodingKeys.self).count == 24 + 1)
        #expect(Self.keys(Job.CodingKeys.self).count == 21)
        #expect(Self.keys(UploadSession.CodingKeys.self).count == 9 + 2)
        #expect(Self.keys(LiveInfo.CodingKeys.self).count == 13)
        #expect(Self.keys(LiveSegment.CodingKeys.self).count == 14)
        #expect(Self.keys(HealthStatus.CodingKeys.self).count == 11)
        #expect(Self.keys(CourtCalibration.CodingKeys.self).count == 7)
        #expect(Self.keys(ReportRecord.CodingKeys.self).count == 9)
        #expect(Self.keys(RosterPlayer.CodingKeys.self).count == 10)
        #expect(Self.keys(TimelineEvent.CodingKeys.self).count == 21)
        #expect(Self.keys(ShotRecord.CodingKeys.self).count == 14)
        #expect(Self.keys(BoxScoreLine.CodingKeys.self).count == 22)
        #expect(Self.keys(TrackAssignment.CodingKeys.self).count == 12)
        #expect(Self.keys(DataQuality.CodingKeys.self).count == 9)
    }

    /// Every Game and Job in every fixture has the same keys (09: 24 and 21); the fixtures of a server with
    /// live games also have `live`.
    @Test func everyGameAndJobInTheFixturesHasEveryKey() throws {
        let gameKeys = Set(Self.keys(Game.CodingKeys.self))
        let jobKeys = Set(Self.keys(Job.CodingKeys.self))
        var games = 0
        var jobs = 0
        for entry in FixtureCatalog.jsonEntries where entry.status < 400 {
            guard let file = entry.file, let model = FixtureModel.model(method: entry.method, endpoint: entry.endpoint, status: entry.status) else { continue }
            let root = try Fixture.jsonObject(file)
            var gameObjects: [[String: Any]] = []
            var jobObjects: [[String: Any]] = []
            switch model {
            case .game: gameObjects = [root as? [String: Any]].compactMap { $0 }
            case .games: gameObjects = root as? [[String: Any]] ?? []
            case .job: jobObjects = [root as? [String: Any]].compactMap { $0 }
            case .jobs: jobObjects = root as? [[String: Any]] ?? []
            case .filmResult, .liveStatus:
                gameObjects = [RawJSON.value(root, at: ["game"]) as? [String: Any]].compactMap { $0 }
                jobObjects = [RawJSON.value(root, at: ["job"]) as? [String: Any]].compactMap { $0 }
            default: continue
            }
            for object in gameObjects {
                games += 1
                let keys = Set(object.keys)
                #expect(keys == gameKeys || keys == gameKeys.subtracting(Self.liveGameKeys), "\(file)")
            }
            for object in jobObjects {
                jobs += 1
                #expect(Set(object.keys) == jobKeys, "\(file)")
            }
        }
        #expect(games > 30)
        #expect(jobs > 30)
    }

    /// The request types use the server's field names (openapi.json `components.schemas`).
    @Test func requestKeysMatchTheOpenAPISchemas() throws {
        let document = try Fixture.decode(JSONValue.self, "openapi.json")
        func properties(_ schema: String) -> Set<String> {
            Set(document["components"]?["schemas"]?[schema]?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        }
        #expect(Set(Self.keys(GameCreate.CodingKeys.self)) == properties("GameCreate"))
        #expect(Set(Self.keys(GameUpdate.CodingKeys.self)) == properties("GameUpdate"))
        #expect(Set(Self.keys(JobCreate.CodingKeys.self)) == properties("JobCreate"))
        #expect(Set(Self.keys(UploadInit.CodingKeys.self)) == properties("UploadInit"))
        #expect(Set(Self.keys(VideoURLRequest.CodingKeys.self)) == properties("VideoUrlRequest"))
        #expect(Set(Self.keys(CalibrationRequest.CodingKeys.self)) == properties("CalibrationRequest"))
        #expect(Set(Self.keys(CalibrationPoint.CodingKeys.self)) == properties("CalibrationPoint"))
        #expect(Set(Self.keys(RosterReplace.CodingKeys.self)) == properties("RosterReplace"))
        #expect(Set(Self.keys(RosterPlayerInput.CodingKeys.self)) == properties("RosterPlayer-Input"))
        #expect(Set(Self.keys(RosterPlayerPatch.CodingKeys.self)) == properties("RosterPlayerPatch"))
        #expect(Set(Self.keys(TrackOverrideBody.CodingKeys.self)) == properties("TrackOverrideBody"))
        #expect(Set(Self.keys(ReportRequest.CodingKeys.self)) == properties("ReportRequest"))
    }

    /// The live-game types use the field names of a server that has live games (its `openapi.json`).
    @Test func liveKeysMatchTheOpenAPISchemas() throws {
        let document = try Fixture.decode(JSONValue.self, "openapi_live.json")
        func properties(_ schema: String) -> Set<String> {
            Set(document["components"]?["schemas"]?[schema]?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        }
        #expect(Set(Self.keys(LiveStart.CodingKeys.self)) == properties("LiveStart"))
        #expect(Set(Self.keys(LiveSegmentInit.CodingKeys.self)) == properties("LiveSegmentInit"))
        #expect(Set(Self.keys(LiveInfo.CodingKeys.self)) == properties("LiveInfo"))
        #expect(Set(Self.keys(LiveSegment.CodingKeys.self)) == properties("LiveSegment"))
        #expect(Set(Self.keys(LiveStatus.CodingKeys.self)) == properties("LiveStatus"))
        #expect(Set(Self.keys(Game.CodingKeys.self)) == properties("Game"))
        #expect(Set(Self.keys(UploadSession.CodingKeys.self)) == properties("UploadSession"))
        #expect(Set(Self.keys(Job.CodingKeys.self)) == properties("Job"))
        let enums = document["components"]?["schemas"]
        func values(_ schema: String) -> [String] {
            enums?[schema]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        #expect(values("LiveState") == LiveState.knownCases.map(\.rawValue))
        #expect(values("LiveEndReason") == LiveEndReason.knownCases.map(\.rawValue))
        #expect(values("LiveSegmentStatus") == LiveSegmentStatus.knownCases.map(\.rawValue))
        #expect(values("JobKind") == JobKind.knownCases.map(\.rawValue))
    }
}
