import Foundation
import Testing
@testable import BasketballScout

/// NaN and ±Infinity arrive as `null` in floats the schema calls non-null (01 §1.4, 09 R22): they decode as
/// `.nan` instead of failing a whole analysis, and encode back as `null`. Bounded floats and required keys
/// stay strict.
nonisolated struct LenientDecodingTests {
    /// One change to a fixture: set `key` of the object at `path` to `value`.
    struct Change {
        let path: [any Sendable]
        let key: String
        let value: Any
    }

    /// The fixture `name` with `changes` applied, as JSON data.
    private func patched(_ name: String, _ changes: [Change]) throws -> Data {
        var root = try Fixture.jsonObject(name)
        for change in changes {
            root = Self.replace(root, change.path[...], key: change.key, value: change.value)
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func replace(_ node: Any, _ path: ArraySlice<any Sendable>, key: String, value: Any) -> Any {
        guard let step = path.first else {
            var object = node as? [String: Any] ?? [:]
            object[key] = value
            return object
        }
        if let name = step as? String, var object = node as? [String: Any] {
            object[name] = replace(object[name] as Any, path.dropFirst(), key: key, value: value)
            return object
        }
        if let index = step as? Int, var array = node as? [Any], array.indices.contains(index) {
            array[index] = replace(array[index], path.dropFirst(), key: key, value: value)
            return array
        }
        return node
    }

    @Test func nullFloatsInTheAnalysisDecodeAsNaN() throws {
        let data = try patched("analysis.json", [
            Change(path: ["timeline", 0], key: "t", value: NSNull()),
            Change(path: ["timeline", 1], key: "confidence", value: NSNull()),
            Change(path: ["plays", 0], key: "start_t", value: NSNull()),
            Change(path: ["possessions", 0], key: "end_t", value: NSNull()),
            Change(path: ["shots", 0], key: "t", value: NSNull()),
            Change(path: ["shots", 0, "player"], key: "match_confidence", value: NSNull()),
            Change(path: ["shots", 0], key: "half_court_xy", value: [NSNull(), 3.5]),
            Change(path: ["data_quality"], key: "ball_coverage", value: NSNull()),
            Change(path: ["track_assignments", 0], key: "match_score", value: NSNull()),
            Change(path: ["track_assignments", 0], key: "votes", value: ["14": NSNull(), "4": 1.5]),
        ])

        let analysis = try ScoutJSON.decode(GameAnalysis.self, from: data)
        #expect(analysis.timeline[0].t.isNaN)
        #expect(analysis.timeline[1].confidence.isNaN)
        #expect(analysis.plays[0].startT.isNaN)
        #expect(analysis.possessions[0].endT.isNaN)
        #expect(analysis.shots[0].t.isNaN)
        #expect(analysis.shots[0].player?.matchConfidence.isNaN == true)
        #expect(analysis.shots[0].halfCourtXY?.x.isNaN == true && analysis.shots[0].halfCourtXY?.y == 3.5)
        #expect(analysis.dataQuality.ballCoverage.isNaN)
        #expect(analysis.trackAssignments[0].matchScore.isNaN)
        #expect(analysis.trackAssignments[0].votes["14"]?.isNaN == true && analysis.trackAssignments[0].votes["4"] == 1.5)

        // Encoding writes them back as null, so a cached copy decodes to the same values.
        let encoded = try ScoutJSON.encode(analysis)
        let raw = try JSONSerialization.jsonObject(with: encoded)
        #expect(RawJSON.value(raw, at: ["timeline", 0, "t"]) is NSNull)
        #expect(RawJSON.value(raw, at: ["track_assignments", 0, "votes", "14"]) is NSNull)
        #expect(RawJSON.value(raw, at: ["shots", 0, "half_court_xy", 0]) is NSNull)
        let again = try ScoutJSON.decode(GameAnalysis.self, from: encoded)
        #expect(again.timeline[0].t.isNaN && again.dataQuality.ballCoverage.isNaN)
        #expect(again.timeline[2] == analysis.timeline[2])
    }

    @Test func nullInACalibrationMatrixDecodesAsNaN() throws {
        let json = #"{"points":[],"matrix":[[1.0,null,0.0],[0.0,1.0,0.0],[0.0,0.0,1.0]],"reprojection_error_ft":null,"frame_t":null,"video_width":null,"video_height":null,"created_at":null}"#
        let calibration = try ScoutJSON.decode(CourtCalibration.self, from: Data(json.utf8))
        #expect(calibration.matrix[0][1].isNaN && calibration.matrix[1][1] == 1)
        #expect(calibration.reprojectionErrorFt.isNaN)
        let encoded = String(decoding: try ScoutJSON.encode(calibration), as: UTF8.self)
        #expect(encoded == #"{"matrix":[[1,null,0],[0,1,0],[0,0,1]],"points":[],"reprojection_error_ft":null}"#)
    }

    @Test func boundedFloatsStayStrict() throws {
        // `Job.progress` (0–100) is bounded on the server and can never be NaN.
        let data = try patched("job_get.json", [Change(path: [], key: "progress", value: NSNull())])
        #expect(throws: DecodingError.self) { try ScoutJSON.decode(Job.self, from: data) }
    }

    @Test func requiredKeysStayRequired() throws {
        let nullStatus = try patched("game_get.json", [Change(path: [], key: "status", value: NSNull())])
        #expect(throws: DecodingError.self) { try ScoutJSON.decode(Game.self, from: nullStatus) }
        var object = try #require(try Fixture.jsonObject("game_get.json") as? [String: Any])
        object.removeValue(forKey: "has_video")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try ScoutJSON.decode(Game.self, from: missing) }
    }

    @Test func nullableKeysMayBeMissing() throws {
        var object = try #require(try Fixture.jsonObject("game_get.json") as? [String: Any])
        object.removeValue(forKey: "location")
        object.removeValue(forKey: "calibration")
        let game = try ScoutJSON.decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(game.location == nil && game.calibration == nil)
    }

    @Test func computedFieldsFallBackWhenMissing() throws {
        let line = #"{"player":{"player_id":null,"jersey":"5","name":"Test Player 2","side":"scouted","match_confidence":0.9},"minutes_est":null,"pts":2,"fgm":1,"fga":3,"tpm":0,"tpa":0,"ftm":2,"fta":2,"oreb":1,"dreb":2,"ast":0,"stl":0,"blk":0,"tov":0,"pf":0,"plus_minus":null,"zones":{"paint":{"made":1,"attempts":3},"mid":{"made":0,"attempts":0},"three":{"made":0,"attempts":0},"unknown":{"made":0,"attempts":0}}}"#
        let decoded = try ScoutJSON.decode(BoxScoreLine.self, from: Data(line.utf8))
        #expect(decoded.player.label == "#5 Test Player 2")
        #expect(decoded.reb == 3 && decoded.fgPct == 0.333 && decoded.tpPct == nil && decoded.ftPct == 1)
        #expect(decoded.zones.paint.pct == 0.333 && decoded.zones.mid.pct == nil)

        var object = try #require(try Fixture.jsonObject("game_get.json") as? [String: Any])
        object.removeValue(forKey: "display_title")
        let game = try ScoutJSON.decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(game.displayTitle == "Test Team A vs Test Team B")

        let player = #"{"id":"p_1","jersey":"0","first_name":" Test ","last_name":"","position":null,"grade":null,"height":null,"notes":null,"fastscout_name":null}"#
        #expect(try ScoutJSON.decode(RosterPlayer.self, from: Data(player.utf8)).name == "Test")
    }

    @Test func sentComputedValuesWin() throws {
        // A null percentage is kept as sent (no attempts), not recomputed.
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let line = try #require(analysis.boxScore(.scouted)?.players.first)
        #expect(line.tpPct == nil && line.tpa == 0)
        #expect(line.fgPct == 0.25 && line.reb == 9)
    }
}
