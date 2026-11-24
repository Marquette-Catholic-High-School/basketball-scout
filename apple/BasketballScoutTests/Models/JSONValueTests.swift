import Foundation
import Testing
@testable import BasketballScout

/// `JSONValue` keeps free-form objects exactly (09 B12) and reads numbers, booleans and nulls correctly.
nonisolated struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let json = #"{"zone_shape":"2-3","follow_score":0.06,"seed":25151,"with_homography":true,"x":null,"also":["spot_up","cut"],"ohv_params":{"conf_thresh":0.25}}"#
        let value = try ScoutJSON.decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["zone_shape"] == .string("2-3"))
        #expect(value["follow_score"]?.doubleValue == 0.06)
        #expect(value["seed"]?.intValue == 25151)
        #expect(value["with_homography"] == .bool(true))
        #expect(value["x"] == .null)
        #expect(value["missing"] == nil)
        #expect(value["also"]?[1]?.stringValue == "cut")
        #expect(value["also"]?[5] == nil)
        #expect(value["ohv_params"]?["conf_thresh"]?.doubleValue == 0.25)
    }

    @Test func keysAreNeverRewritten() throws {
        // A key strategy must not reach free-form keys (09 B12): even a snake-case-converting decoder keeps them.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(JSONValue.self, from: Data(#"{"zone_shape":"2-3","roll_or_pop":{"coach_focus":1}}"#.utf8))
        #expect(value.objectValue?.keys.sorted() == ["roll_or_pop", "zone_shape"])
        #expect(value["roll_or_pop"]?["coach_focus"]?.intValue == 1)
    }

    @Test func booleansAreNotNumbers() throws {
        let values = try ScoutJSON.decode([JSONValue].self, from: Data("[true, 1, 0, false, 1.5, \"1\"]".utf8))
        #expect(values == [.bool(true), .number(1), .number(0), .bool(false), .number(1.5), .string("1")])
        #expect(values[1].boolValue == nil && values[0].doubleValue == nil)
    }

    @Test func numbers() throws {
        let values = try ScoutJSON.decode([JSONValue].self, from: Data("[3, 3.0, 3.5, -4.501271471773479e-17, 1e+16, 12884901888]".utf8))
        #expect(values[0].intValue == 3 && values[1].intValue == 3 && values[2].intValue == nil)
        #expect(values[3].doubleValue == -4.501271471773479e-17)
        #expect(values[4].intValue == 10_000_000_000_000_000)
        #expect(values[5].intValue == 12_884_901_888)
    }

    @Test func roundTripsAndWritesNonFiniteAsNull() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        #expect(try ScoutJSON.decode(JSONValue.self, from: ScoutJSON.encode(value)) == value)
        #expect(String(decoding: try ScoutJSON.encode(JSONValue.array([.number(.nan), .number(.infinity)])), as: UTF8.self) == "[null,null]")
    }

    @Test func truthinessFollowsJavaScript() {
        #expect(!JSONValue.null.isTruthy && !JSONValue.bool(false).isTruthy && !JSONValue.number(0).isTruthy)
        #expect(!JSONValue.number(.nan).isTruthy && !JSONValue.string("").isTruthy)
        #expect(JSONValue.bool(true).isTruthy && JSONValue.number(2).isTruthy && JSONValue.string("no").isTruthy)
        #expect(JSONValue.array([]).isTruthy && JSONValue.object([:]).isTruthy)
    }

    @Test func freeFormFieldsKeepTheirKeysInModels() throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        #expect(Set(analysis.pipeline.options.keys) == ["seed", "with_homography", "ocr_noise"])
        let attrKeys = Set(analysis.plays.flatMap(\.attrs.keys))
        #expect(attrKeys.isSuperset(of: ["zone_shape", "roll_or_pop", "handler_direction", "screen_side", "follow_score", "anchor_ratio"]))
        let job = try Fixture.decode(Job.self, "job_create_reanalyze_2.json")
        #expect(job.params.keys.sorted() == ["report"])
        let imported = try Fixture.decode(RosterImportResult.self, "roster_import.json")
        #expect(imported.skippedRows.first?.fields.keys.sorted() == ["reason", "row"])
    }
}
