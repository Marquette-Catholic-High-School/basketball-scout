import Foundation
import Testing
@testable import BasketballScout

/// Request bodies: exact wire form, round trips, and the bodies the fixture captures really sent.
nonisolated struct RequestEncodingTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try ScoutJSON.encode(value), as: UTF8.self)
    }

    private func roundTrips<T: Codable & Equatable>(_ value: T) throws -> Bool {
        try ScoutJSON.decode(T.self, from: ScoutJSON.encode(value)) == value
    }

    @Test func gameCreate() throws {
        let create = GameCreate(scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"), location: "Test Gym", level: "Varsity", notes: "Fixture game", scoutedColor: "dark")
        #expect(try json(create) == #"{"game_date":"2026-11-07","level":"Varsity","location":"Test Gym","notes":"Fixture game","other_team":"Test Team B","scouted_color":"dark","scouted_team":"Test Team A","title":null}"#)
        #expect(try roundTrips(create))
        // other_team is never null (09 D1 #3).
        #expect(try json(GameCreate(scoutedTeam: "Test Team C")).contains(#""other_team":"""#))
    }

    @Test func gameCreateNormalizesLikeTheForm() {
        let typed = GameCreate(scoutedTeam: "  Test Team A ", otherTeam: "  ", title: " ", location: "\nTest Gym ", level: "", notes: "  note ", scoutedColor: "dark")
        let clean = typed.normalized()
        #expect(clean == GameCreate(scoutedTeam: "Test Team A", otherTeam: "", title: nil, location: "Test Gym", level: nil, notes: "note", scoutedColor: "dark"))
    }

    @Test func jobCreate() throws {
        #expect(try json(JobCreate.analyze) == #"{"kind":"analyze"}"#)
        #expect(try json(JobCreate.reanalyze) == #"{"kind":"reanalyze"}"#)
        #expect(try json(JobCreate(kind: .reanalyze, params: ["report": false])) == #"{"kind":"reanalyze","params":{"report":false}}"#)
        #expect(try json(JobCreate.report(coachFocus: "  We play a 2-3 zone \n")) == #"{"kind":"report","params":{"coach_focus":"We play a 2-3 zone"}}"#)
        #expect(try json(JobCreate.report(coachFocus: "   ")) == #"{"kind":"report","params":{"coach_focus":null}}"#)
        #expect(try roundTrips(JobCreate(kind: .unknown("future"), params: ["x": [1, "a", nil]])))
        #expect(try json(JobCreate(kind: .unknown("future"))) == #"{"kind":"future"}"#)
    }

    @Test func reportRequest() throws {
        #expect(try json(ReportRequest()) == #"{"coach_focus":null}"#)
        #expect(try json(ReportRequest(coachFocus: "  Who do we leave open?  ")) == #"{"coach_focus":"Who do we leave open?"}"#)
        #expect(ReportRequest(coachFocus: "\n\t ").coachFocus == nil)
        #expect(ReportRequest(coachFocus: String(repeating: "a", count: 2000)).isFocusWithinLimit)
        #expect(!ReportRequest(coachFocus: String(repeating: "a", count: 2001)).isFocusWithinLimit)
        // Code points, not grapheme clusters (01 §1.4): a flag is two scalars.
        #expect(!ReportRequest(coachFocus: String(repeating: "🇺🇸", count: 1001)).isFocusWithinLimit)
    }

    @Test func uploadInit() throws {
        #expect(try json(UploadInit(filename: "test-film.mp4", size: 41284, contentType: "video/mp4")) == #"{"content_type":"video/mp4","filename":"test-film.mp4","size":41284}"#)
        #expect(try json(UploadInit(filename: "big-film.mov", size: 12_884_901_888)) == #"{"content_type":null,"filename":"big-film.mov","size":12884901888}"#)
        #expect(UploadInit(filename: "Game Film.MP4", size: 1).hasAllowedExtension)
        #expect(UploadInit(filename: #"C:\fakepath\film.m4v"#, size: 1).hasAllowedExtension)
        #expect(!UploadInit(filename: "film.avi", size: 1).hasAllowedExtension)
        #expect(!UploadInit(filename: ".mp4", size: 1).hasAllowedExtension)
        #expect(!UploadInit(filename: "dir/.mov", size: 1).hasAllowedExtension)
        #expect(!UploadInit(filename: "film", size: 1).hasAllowedExtension)
    }

    @Test func videoURLRequest() throws {
        #expect(try json(VideoURLRequest(url: "https://example.com/films/test-film.mp4", filename: "Test Team D film.mp4")) == #"{"filename":"Test Team D film.mp4","url":"https://example.com/films/test-film.mp4"}"#)
        #expect(try roundTrips(VideoURLRequest(url: "https://example.com/a.mp4")))
    }

    @Test func calibrationRequest() throws {
        let request = CalibrationRequest(
            points: [CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 40, y: 330.5))],
            frameT: 1.5, videoWidth: 640, videoHeight: 360)
        #expect(try json(request) == #"{"frame_t":1.5,"points":[{"landmark":"left_baseline_near_corner","px":[40,330.5]}],"video_height":360,"video_width":640}"#)
        #expect(try json(CalibrationRequest(points: [])) == #"{"frame_t":null,"points":[],"video_height":null,"video_width":null}"#)
        #expect(try roundTrips(request))
    }

    @Test func rosterBodies() throws {
        let newPlayer = RosterPlayerInput(jersey: "00", firstName: "Test", lastName: "Player 1", position: "G")
        // No id (the server makes one, 09 R42); names never null; optional fields null.
        #expect(try json(newPlayer) == #"{"fastscout_name":null,"first_name":"Test","grade":null,"height":null,"jersey":"00","last_name":"Player 1","notes":null,"position":"G"}"#)
        let replace = RosterReplace(teamName: "Test Team A", players: [RosterPlayerInput(id: "p_fixture01", jersey: "1")])
        #expect(try json(replace) == #"{"players":[{"fastscout_name":null,"first_name":"","grade":null,"height":null,"id":"p_fixture01","jersey":"1","last_name":"","notes":null,"position":null}],"team_name":"Test Team A"}"#)
        #expect(try json(RosterReplace(teamName: nil, players: [])) == #"{"players":[],"team_name":null}"#)
        #expect(try roundTrips(replace))

        let roster = try Fixture.decode(Roster.self, "roster_get_other.json")
        let player = try #require(roster.players.first)
        #expect(player.input.id == player.id && player.input.jersey == player.jersey)
    }

    @Test func rosterPlayerInputNormalizesLikeTheEditor() {
        let typed = RosterPlayerInput(jersey: " # 5 ", firstName: " Test ", lastName: "Player 1  ", position: " ", grade: "Sr ", notes: "")
        #expect(typed.normalized() == RosterPlayerInput(jersey: "5", firstName: "Test", lastName: "Player 1", position: nil, grade: "Sr", notes: nil))
        #expect(RosterPlayerInput(jersey: " ", firstName: "", lastName: " ").isBlank)
        #expect(!RosterPlayerInput(jersey: "", notes: "x").isBlank)
    }

    @Test func trackOverrideBodies() throws {
        #expect(try json(TrackOverrideBody.assign(trackID: 7, playerID: "p_fixture05", side: .scouted)) == #"{"ignore":false,"player_id":"p_fixture05","side":"scouted","track_id":7}"#)
        #expect(try json(TrackOverrideBody.unknownPlayer(trackID: 12, side: nil)) == #"{"ignore":false,"player_id":null,"side":null,"track_id":12}"#)
        #expect(try json(TrackOverrideBody.notAPlayer(trackID: 13, side: .other)) == #"{"ignore":true,"player_id":null,"side":"other","track_id":13}"#)
        #expect(try json(TrackOverrideBody(ignore: true)) == #"{"ignore":true,"player_id":null,"side":null}"#)
        #expect(try ScoutJSON.decode(TrackOverrideBody.self, from: Data("{}".utf8)) == TrackOverrideBody())
    }

    @Test func importModeIsAFormValue() {
        #expect(RosterImportMode.replace.rawValue == "replace")
        #expect(RosterImportMode.merge.rawValue == "merge")
        #expect(RosterImportMode.knownCases == [.replace, .merge])
    }

    // MARK: The bodies the fixture captures sent (the server answered 2xx to each)

    /// Decodes a captured request body into the app's request type and encodes it again: every key/value
    /// the capture sent comes back, and PATCH bodies keep exactly their keys. Elsewhere the encoders may add
    /// a key with the server's default (null, `other_team`/`first_name`/`last_name` `""`, `ignore` false) or
    /// leave out empty `params`, which the server treats as omitted (01 §4).
    @Test(arguments: [
        "game_create", "game_create_minimal", "game_create_for_link", "game_patch", "game_patch_restore",
        "game_patch_team_id_map", "roster_add_player", "roster_add_player_2", "roster_add_player_3", "roster_patch_player",
        "roster_replace", "roster_replace_scouted_matching", "roster_replace_other_matching", "upload_create",
        "upload_create_game3", "upload_create_large", "track_override_assign", "track_override_ignore",
        "track_override_unassign", "calibration_put", "calibration_put_minimal", "job_create_reanalyze",
        "job_create_reanalyze_2", "job_create_analyze_full", "video_url_set", "video_url_set_no_autostart",
    ])
    func capturedRequestBodiesSurviveTheRequestTypes(_ name: String) throws {
        let entry = try #require(FixtureCatalog.manifest.first { $0.name == name })
        let sent = try #require(entry.request.body)
        let sentData = try ScoutJSON.encode(sent)
        let resent: Data
        var exactKeys = false
        switch (entry.method, entry.endpoint) {
        case ("POST", "/api/games"): resent = try ScoutJSON.encode(ScoutJSON.decode(GameCreate.self, from: sentData))
        case ("PATCH", "/api/games/{game_id}"):
            resent = try ScoutJSON.encode(ScoutJSON.decode(GameUpdate.self, from: sentData))
            exactKeys = true
        case ("POST", "/api/games/{game_id}/rosters/{side}/players"): resent = try ScoutJSON.encode(ScoutJSON.decode(RosterPlayerInput.self, from: sentData))
        case ("PATCH", "/api/games/{game_id}/rosters/{side}/players/{player_id}"):
            resent = try ScoutJSON.encode(ScoutJSON.decode(RosterPlayerPatch.self, from: sentData))
            exactKeys = true
        case ("PUT", "/api/games/{game_id}/rosters/{side}"): resent = try ScoutJSON.encode(ScoutJSON.decode(RosterReplace.self, from: sentData))
        case ("POST", "/api/games/{game_id}/uploads"): resent = try ScoutJSON.encode(ScoutJSON.decode(UploadInit.self, from: sentData))
        case ("PUT", "/api/games/{game_id}/tracks/{track_id}"): resent = try ScoutJSON.encode(ScoutJSON.decode(TrackOverrideBody.self, from: sentData))
        case ("PUT", "/api/games/{game_id}/calibration"): resent = try ScoutJSON.encode(ScoutJSON.decode(CalibrationRequest.self, from: sentData))
        case ("POST", "/api/games/{game_id}/jobs"): resent = try ScoutJSON.encode(ScoutJSON.decode(JobCreate.self, from: sentData))
        case ("POST", "/api/games/{game_id}/video-url"): resent = try ScoutJSON.encode(ScoutJSON.decode(VideoURLRequest.self, from: sentData))
        default:
            Issue.record("No request type for \(entry.description)")
            return
        }
        let original = try ScoutJSON.decode(JSONValue.self, from: sentData)
        let again = try ScoutJSON.decode(JSONValue.self, from: resent)
        if exactKeys {
            #expect(again == original)
        } else {
            #expect(Self.withoutServerDefaults(again) == Self.withoutServerDefaults(original))
        }
    }

    /// Removes members whose value is the server's default for an omitted key (schemas.py request models).
    static func withoutServerDefaults(_ value: JSONValue) -> JSONValue {
        let defaults: [String: JSONValue] = [
            "params": .object([:]), "ignore": .bool(false), "other_team": .string(""), "first_name": .string(""),
            "last_name": .string(""),
        ]
        switch value {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, member) in object where member != .null && defaults[key] != member {
                result[key] = withoutServerDefaults(member)
            }
            return .object(result)
        case .array(let array):
            return .array(array.map(withoutServerDefaults))
        default:
            return value
        }
    }
}
