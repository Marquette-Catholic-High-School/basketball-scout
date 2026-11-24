import Foundation
import Testing
@testable import BasketballScout

/// `Patch` (unset / null / value) and the PATCH bodies built from it (01 §4.2, 05 §4.6, 09 R26).
nonisolated struct PatchTests {
    private struct Body: Codable, Equatable {
        var name: Patch<String> = .unset
        var count: Patch<Int> = .unset
        var map: Patch<[String: TeamSide]> = .unset

        enum CodingKeys: String, CodingKey {
            case name
            case count
            case map = "team_map"
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try ScoutJSON.encode(value), as: UTF8.self)
    }

    @Test func encodesNothingNullOrTheValue() throws {
        #expect(try json(Body()) == "{}")
        #expect(try json(Body(name: .null)) == #"{"name":null}"#)
        #expect(try json(Body(name: .value("x"), count: .value(3))) == #"{"count":3,"name":"x"}"#)
        #expect(try json(Body(map: .value(["0": .scouted, "1": .other]))) == #"{"team_map":{"0":"scouted","1":"other"}}"#)
    }

    @Test func decodesMissingNullAndValue() throws {
        let decoded = try ScoutJSON.decode(Body.self, from: Data(#"{"name":null,"team_map":{"1":"weird"}}"#.utf8))
        #expect(decoded.name == .null)
        #expect(decoded.count == .unset)
        #expect(decoded.map == .value(["1": .unknown("weird")]))
    }

    @Test func unsetHasNoStandaloneForm() {
        #expect(throws: EncodingError.self) { try ScoutJSON.encode([Patch<String>.unset]) }
        #expect((try? json([Patch<String>.null, .value("a")])) == #"[null,"a"]"#)
    }

    @Test func helpers() {
        #expect(Patch<String>("x") == .value("x"))
        #expect(Patch<String>(nil) == .null)
        #expect(Patch<String>.unset.isUnset && Patch<String>.null.isNull)
        #expect(Patch<String>.value("x").valueIfSet == "x" && Patch<String>.null.valueIfSet == nil)
        #expect(Patch<String>.unset.applied(to: "old") == "old")
        #expect(Patch<String>.null.applied(to: "old") == nil)
        #expect(Patch<String>.value("new").applied(to: "old") == "new")
    }

    // MARK: GameUpdate

    @Test func gameUpdateSendsOnlyThePatchedKeys() throws {
        #expect(try json(GameUpdate()) == "{}")
        #expect(GameUpdate().isEmpty)
        let patch = GameUpdate(location: .value("Test Arena"), level: .value("JV"), notes: .null)
        #expect(try json(patch) == #"{"level":"JV","location":"Test Arena","notes":null}"#)
        #expect(try json(GameUpdate(gameDate: .value(GameDate("2026-11-07")!))) == #"{"game_date":"2026-11-07"}"#)
        #expect(try json(GameUpdate(gameDate: .null, teamIDMap: .null)) == #"{"game_date":null,"team_id_map":null}"#)
    }

    @Test func gameUpdateTeamMapUsesStringKeys() throws {
        // 01 §1.2: dict[int, TeamSide] → JSON object with string keys (game_patch_team_id_map).
        #expect(try json(GameUpdate.confirmTeams(scoutedTeamID: 1, otherTeamID: 0)) == #"{"team_id_map":{"0":"other","1":"scouted"}}"#)
    }

    @Test func gameUpdateNeverSendsForbiddenNulls() throws {
        // scouted_team: null → 422 on the server, so it never leaves the app.
        #expect(throws: EncodingError.self) { try ScoutJSON.encode(GameUpdate(scoutedTeam: .null)) }
        // other_team: null is stored as "" — send "" instead (09 D1 #3).
        #expect(try json(GameUpdate(otherTeam: .null)) == #"{"other_team":""}"#)
        // title: null is allowed (stored as "").
        #expect(try json(GameUpdate(title: .null)) == #"{"title":null}"#)
    }

    @Test func gameUpdateRoundTrips() throws {
        let patch = GameUpdate(scoutedTeam: .value("Test Team A"), title: .null, scoutedColor: .value("#1f3a93"), teamIDMap: .value(["0": .scouted]))
        #expect(try ScoutJSON.decode(GameUpdate.self, from: ScoutJSON.encode(patch)) == patch)
    }

    // MARK: RosterPlayerPatch

    @Test func playerPatchRules() throws {
        #expect(try json(RosterPlayerPatch()) == "{}")
        #expect(RosterPlayerPatch().isEmpty)
        let patch = RosterPlayerPatch(position: .value("C"), notes: .value("Fixture note"), fastscoutName: .value("Test Player 2"))
        #expect(try json(patch) == #"{"fastscout_name":"Test Player 2","notes":"Fixture note","position":"C"}"#)
        #expect(throws: EncodingError.self) { try ScoutJSON.encode(RosterPlayerPatch(jersey: .null)) }
        #expect(try json(RosterPlayerPatch(firstName: .null, lastName: .null)) == #"{"first_name":"","last_name":""}"#)
        #expect(try json(RosterPlayerPatch(grade: .null, height: .null)) == #"{"grade":null,"height":null}"#)
        #expect(try json(RosterPlayerPatch(jersey: .value("05"))) == #"{"jersey":"05"}"#)
    }
}
