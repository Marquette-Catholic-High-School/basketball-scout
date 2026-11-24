import Foundation
import Testing
@testable import BasketballScout

/// What a request body must be.
nonisolated enum ExpectedBody: Sendable {
    case none
    /// The exact JSON bytes (`ScoutJSON` sorts keys).
    case json(String)
    /// Raw bytes (a film chunk).
    case bytes(Data)
    /// The roster import: a `file` part and form fields.
    case multipart(filename: String, fileContentType: String, fileData: Data, fields: [String: String])
}

/// One `APIClient` method: the request it must send and the fixture it gets back (decoded through the
/// client and compared with the fixture decoded directly).
nonisolated struct RouteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let method: String
    let path: String
    let query: String?
    let contentType: String?
    let accept: String
    let sendsCredentials: Bool
    let body: ExpectedBody
    /// The 08 manifest capture whose request the server accepted (method, path, query, body).
    let capture: String?
    let response: StubResponse
    let call: @Sendable (APIClient) async throws -> Void

    var testDescription: String { name }
}

nonisolated extension RouteCase {
    static let game = "g_e934f8c21058"

    static func route(
        _ name: String, _ method: String, _ path: String, query: String? = nil, contentType: String? = nil,
        accept: String = "application/json", credentials: Bool = true, body: ExpectedBody = .none,
        capture: String? = nil, response: StubResponse, call: @escaping @Sendable (APIClient) async throws -> Void
    ) -> RouteCase {
        RouteCase(
            name: name, method: method, path: path, query: query, contentType: contentType, accept: accept,
            sendsCredentials: credentials, body: body, capture: capture, response: response, call: call)
    }

    /// Checks `value` against fixture `name` decoded with the app's decoder.
    static func expectDecoded<T: Decodable & Equatable>(_ value: T, _ type: T.Type, _ name: String) throws {
        let expected = try Fixture.decode(type, name)
        #expect(value == expected, "\(name)")
    }

    /// Checks a download: server file name, bytes, type, protected temporary location; then removes it.
    static func expectDownload(_ file: DownloadedFile, filename: String, fixture: String, contentType: String) throws {
        defer { file.remove() }
        #expect(file.filename == filename)
        #expect(file.url.lastPathComponent == filename)
        #expect(file.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == DownloadedFile.folderName)
        #expect(file.contentType == contentType)
        let data = try Data(contentsOf: file.url)
        let expected = try Fixture.data(fixture)
        #expect(data == expected)
        #expect(file.byteCount == data.count)
        #expect(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    static func attachment(_ filename: String, type: String) -> [String: String] {
        ["Content-Disposition": "attachment; filename=\"\(filename)\"", "Content-Type": type]
    }

    /// 09 C1: the 202 body of `POST /api/games/{id}/reports` (08 has no 202 capture).
    static let reportJob = #"{"id":"j_22acdd6ecdcf","game_id":"g_8edaf05f84e7","kind":"report","status":"queued","stage":"queued","progress":0.0,"message":"Waiting for a worker","error":null,"warnings":[],"params":{"coach_focus":"  We play a 2-3 zone  "},"attempts":0,"max_attempts":3,"processor":null,"external_id":null,"cancel_requested":false,"worker_id":null,"lease_expires_at":null,"created_at":"2026-11-11T20:24:42.030060Z","started_at":null,"finished_at":null,"updated_at":"2026-11-11T20:24:42.030060Z"}"#

    // MARK: - Every route (09 §A)

    static let all: [RouteCase] = system + games + uploads + live + media + jobs + reports + rosters + tracks + exports

    static let system: [RouteCase] = [
        route("healthLive", "GET", "/api/health/live", credentials: false, capture: "health_live",
              response: .fixture("health_live.json")) { client in
            try expectDecoded(try await client.healthLive(), HealthLive.self, "health_live.json")
        },
        route("health", "GET", "/api/health", capture: "health", response: .fixture("health.json")) { client in
            try expectDecoded(try await client.health(), HealthStatus.self, "health.json")
        },
        route("courtLandmarks", "GET", "/api/court/landmarks", capture: "court_landmarks",
              response: .fixture("court_landmarks.json")) { client in
            let landmarks = try await client.courtLandmarks()
            try expectDecoded(landmarks, CourtLandmarks.self, "court_landmarks.json")
            #expect(landmarks.landmarks.map(\.name) == CourtLandmarks.documentedOrder)
        },
        route("openAPIDocument", "GET", "/api/openapi.json", capture: "openapi", response: .fixture("openapi.json")) { client in
            try expectDecoded(try await client.openAPIDocument(), JSONValue.self, "openapi.json")
        },
    ]

    static let games: [RouteCase] = [
        route("games", "GET", "/api/games", capture: "games_list", response: .fixture("games_list.json")) { client in
            try expectDecoded(try await client.games(), [Game].self, "games_list.json")
        },
        route("createGame", "POST", "/api/games", contentType: "application/json",
              body: .json(#"{"game_date":"2026-11-07","level":"Varsity","location":"Test Gym","notes":"Fixture game","other_team":"Test Team B","scouted_color":"dark","scouted_team":"Test Team A","title":null}"#),
              capture: "game_create", response: .fixture("game_create.json", status: 201)) { client in
            let body = GameCreate(
                scoutedTeam: "Test Team A", otherTeam: "Test Team B", gameDate: GameDate("2026-11-07"),
                location: "Test Gym", level: "Varsity", notes: "Fixture game", scoutedColor: "dark")
            try expectDecoded(try await client.createGame(body), Game.self, "game_create.json")
        },
        route("game", "GET", "/api/games/\(game)", capture: "game_get", response: .fixture("game_get.json")) { client in
            try expectDecoded(try await client.game(id: game), Game.self, "game_get.json")
        },
        route("updateGame", "PATCH", "/api/games/\(game)", contentType: "application/json",
              body: .json(#"{"level":"JV","location":"Test Arena","notes":null}"#),
              capture: "game_patch", response: .fixture("game_patch.json")) { client in
            let update = GameUpdate(location: .value("Test Arena"), level: .value("JV"), notes: .null)
            try expectDecoded(try await client.updateGame(id: game, update), Game.self, "game_patch.json")
        },
        route("deleteGame", "DELETE", "/api/games/g_3864d2c4f9c8", capture: "game_delete", response: .empty(204)) { client in
            try await client.deleteGame(id: "g_3864d2c4f9c8")
        },
        route("analysis", "GET", "/api/games/\(game)/analysis", capture: "analysis", response: .fixture("analysis.json")) { client in
            let analysis = try await client.analysis(gameID: game)
            let expected = try Fixture.decode(GameAnalysis.self, "analysis.json")
            // NaN (null) floats make == useless; compare the canonical encodings.
            #expect(try ScoutJSON.encode(analysis) == ScoutJSON.encode(expected))
            #expect(analysis.gameID == game)
        },
    ]

    static let uploads: [RouteCase] = [
        route("createUpload", "POST", "/api/games/\(game)/uploads", contentType: "application/json",
              body: .json(#"{"content_type":"video/mp4","filename":"test-film.mp4","size":41284}"#),
              capture: "upload_create", response: .fixture("upload_create.json", status: 201)) { client in
            let session = try await client.createUpload(gameID: game, UploadInit(filename: "test-film.mp4", size: 41284, contentType: "video/mp4"))
            try expectDecoded(session, UploadSession.self, "upload_create.json")
        },
        route("upload", "GET", "/api/uploads/u_4b596795629f", capture: "upload_get_partial",
              response: .fixture("upload_get_partial.json")) { client in
            try expectDecoded(try await client.upload(id: "u_4b596795629f"), UploadSession.self, "upload_get_partial.json")
        },
        route("uploadChunk", "PUT", "/api/uploads/u_4b596795629f/chunk", query: "offset=20000",
              contentType: "application/octet-stream", body: .bytes(chunkBytes),
              capture: "upload_chunk_2", response: .fixture("upload_chunk_2.json")) { client in
            let session = try await client.uploadChunk(uploadID: "u_4b596795629f", offset: 20000, data: chunkBytes)
            try expectDecoded(session, UploadSession.self, "upload_chunk_2.json")
        },
        route("completeUpload", "POST", "/api/uploads/u_4b596795629f/complete", query: "auto_start=true",
              capture: "upload_complete", response: .fixture("upload_complete.json")) { client in
            try expectDecoded(try await client.completeUpload(id: "u_4b596795629f"), FilmResult.self, "upload_complete.json")
        },
        route("completeUploadWithoutStart", "POST", "/api/uploads/u_4b596795629f/complete", query: "auto_start=false",
              response: .fixture("upload_complete_no_autostart.json")) { client in
            let result = try await client.completeUpload(id: "u_4b596795629f", autoStart: false)
            try expectDecoded(result, FilmResult.self, "upload_complete_no_autostart.json")
        },
        route("deleteUpload", "DELETE", "/api/uploads/u_7574fb5f7bd3", capture: "upload_delete", response: .empty(204)) { client in
            try await client.deleteUpload(id: "u_7574fb5f7bd3")
        },
        route("setVideoURL", "POST", "/api/games/g_5e21fcf0b398/video-url", query: "auto_start=true",
              contentType: "application/json",
              body: .json(#"{"filename":"Test Team D film.mp4","url":"https://example.com/films/test-film.mp4"}"#),
              capture: "video_url_set", response: .fixture("video_url_set.json")) { client in
            let body = VideoURLRequest(url: "https://example.com/films/test-film.mp4", filename: "Test Team D film.mp4")
            try expectDecoded(try await client.setVideoURL(gameID: "g_5e21fcf0b398", body), FilmResult.self, "video_url_set.json")
        },
    ]

    /// 21,284 bytes, like the second chunk of the 08 test film.
    static let chunkBytes = Data((0..<21284).map { UInt8($0 % 251) })

    static let media: [RouteCase] = [
        route("saveCalibration", "PUT", "/api/games/\(game)/calibration", contentType: "application/json",
              body: .json(#"{"frame_t":null,"points":[{"landmark":"left_baseline_near_corner","px":[40,330]},{"landmark":"left_baseline_far_corner","px":[150,120]},{"landmark":"right_baseline_near_corner","px":[600,330]},{"landmark":"right_baseline_far_corner","px":[490,120]}],"video_height":null,"video_width":null}"#),
              capture: "calibration_put_minimal", response: .fixture("calibration_put_minimal.json")) { client in
            let body = CalibrationRequest(points: [
                CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 40, y: 330)),
                CalibrationPoint(landmark: "left_baseline_far_corner", px: XY(x: 150, y: 120)),
                CalibrationPoint(landmark: "right_baseline_near_corner", px: XY(x: 600, y: 330)),
                CalibrationPoint(landmark: "right_baseline_far_corner", px: XY(x: 490, y: 120)),
            ])
            let calibration = try await client.saveCalibration(gameID: game, body)
            #expect(try ScoutJSON.encode(calibration) == ScoutJSON.encode(Fixture.decode(CourtCalibration.self, "calibration_put_minimal.json")))
        },
        route("deleteCalibration", "DELETE", "/api/games/\(game)/calibration", capture: "calibration_delete",
              response: .empty(204)) { client in
            try await client.deleteCalibration(gameID: game)
        },
    ]

    /// The game of the live fixtures (docs/LIVE.md).
    static let liveGame = "g_bfd495c87b5c"

    static let live: [RouteCase] = [
        route("startLive", "POST", "/api/games/\(liveGame)/live", capture: "live_start",
              response: .fixture("live_start.json", status: 201)) { client in
            // No body: the server picks the part length.
            try expectDecoded(try await client.startLive(gameID: liveGame), LiveStatus.self, "live_start.json")
        },
        route("startLiveWithPartLength", "POST", "/api/games/\(liveGame)/live", contentType: "application/json",
              body: .json(#"{"segment_seconds":90}"#), response: .fixture("live_start_again.json")) { client in
            let status = try await client.startLive(gameID: liveGame, segmentSeconds: 90)
            try expectDecoded(status, LiveStatus.self, "live_start_again.json")
        },
        route("liveStatus", "GET", "/api/games/\(liveGame)/live", capture: "live_status_capturing",
              response: .fixture("live_status_capturing.json")) { client in
            try expectDecoded(try await client.liveStatus(gameID: liveGame), LiveStatus.self, "live_status_capturing.json")
        },
        route("createLiveSegmentUpload", "POST", "/api/games/\(liveGame)/live/segments", contentType: "application/json",
              body: .json(#"{"duration_s":120.133333,"filename":"part-00000.mp4","index":0,"size":4096}"#),
              capture: "live_segment_create", response: .fixture("live_segment_create.json", status: 201)) { client in
            let session = try await client.createLiveSegmentUpload(
                gameID: liveGame, LiveSegmentInit(index: 0, durationS: 120.133333, size: 4096, filename: "part-00000.mp4"))
            try expectDecoded(session, UploadSession.self, "live_segment_create.json")
            #expect(session.liveSegment == 0)
        },
        route("finishLive", "POST", "/api/games/\(liveGame)/live/finish", capture: "live_finish",
              response: .fixture("live_finish.json")) { client in
            try expectDecoded(try await client.finishLive(gameID: liveGame), LiveStatus.self, "live_finish.json")
        },
        // A live part's bytes and its `complete` go through the film upload routes.
        route("uploadChunk (live part)", "PUT", "/api/uploads/u_73f536e960fd/chunk", query: "offset=1500",
              contentType: "application/octet-stream", body: .bytes(livePartRest),
              capture: "live_segment_chunk", response: .fixture("live_segment_chunk.json")) { client in
            let session = try await client.uploadChunk(uploadID: "u_73f536e960fd", offset: 1500, data: livePartRest)
            try expectDecoded(session, UploadSession.self, "live_segment_chunk.json")
        },
        route("completeUpload (live part)", "POST", "/api/uploads/u_73f536e960fd/complete", query: "auto_start=true",
              capture: "live_segment_complete", response: .fixture("live_segment_complete.json")) { client in
            let result = try await client.completeUpload(id: "u_73f536e960fd")
            try expectDecoded(result, FilmResult.self, "live_segment_complete.json")
            #expect(result.game.live?.segmentsReceived == 1)
        },
    ]

    /// The bytes of the live part's second chunk in the capture (2596 of them; the content does not matter here).
    static let livePartRest = Data((0..<2596).map { UInt8($0 % 251) })

    static let jobs: [RouteCase] = [
        route("startJob", "POST", "/api/games/\(game)/jobs", contentType: "application/json", body: .json(#"{"kind":"analyze"}"#),
              capture: "job_create_analyze_full", response: .fixture("job_create_analyze_full.json", status: 201)) { client in
            try expectDecoded(try await client.startJob(gameID: game, .analyze), Job.self, "job_create_analyze_full.json")
        },
        route("startReanalyze", "POST", "/api/games/\(game)/jobs", contentType: "application/json", body: .json(#"{"kind":"reanalyze"}"#),
              response: .fixture("job_create_reanalyze.json", status: 201)) { client in
            try expectDecoded(try await client.startJob(gameID: game, .reanalyze), Job.self, "job_create_reanalyze.json")
        },
        route("jobs", "GET", "/api/games/\(game)/jobs", capture: "jobs_list", response: .fixture("jobs_list.json")) { client in
            try expectDecoded(try await client.jobs(gameID: game), [Job].self, "jobs_list.json")
        },
        route("job", "GET", "/api/jobs/j_a337003622c0", capture: "job_get", response: .fixture("job_get.json")) { client in
            try expectDecoded(try await client.job(id: "j_a337003622c0"), Job.self, "job_get.json")
        },
        route("cancelJob", "POST", "/api/jobs/j_303a5ba171e4/cancel", capture: "job_cancel_queued",
              response: .fixture("job_cancel_queued.json")) { client in
            try expectDecoded(try await client.cancelJob(id: "j_303a5ba171e4"), Job.self, "job_cancel_queued.json")
        },
        route("retryJob", "POST", "/api/jobs/j_303a5ba171e4/retry", capture: "job_retry_cancelled",
              response: .fixture("job_retry_cancelled.json")) { client in
            try expectDecoded(try await client.retryJob(id: "j_303a5ba171e4"), Job.self, "job_retry_cancelled.json")
        },
    ]

    static let reports: [RouteCase] = [
        route("generateReport", "POST", "/api/games/\(game)/reports", contentType: "application/json",
              body: .json(#"{"coach_focus":null}"#), response: .json(202, reportJob)) { client in
            let job = try await client.generateReport(gameID: game)
            #expect(job.id == "j_22acdd6ecdcf" && job.kind == .report && job.status == .queued)
        },
        route("generateReportWithFocus", "POST", "/api/games/\(game)/reports", contentType: "application/json",
              body: .json(#"{"coach_focus":"We play a 2-3 zone"}"#), response: .json(202, reportJob)) { client in
            _ = try await client.generateReport(gameID: game, ReportRequest(coachFocus: "  We play a 2-3 zone  "))
        },
        route("reports", "GET", "/api/games/\(game)/reports", capture: "reports_list_seeded",
              response: .fixture("reports_list_seeded.json")) { client in
            try expectDecoded(try await client.reports(gameID: game), [ReportRecord].self, "reports_list_seeded.json")
        },
        route("report", "GET", "/api/reports/r_cb24d96d31d7", capture: "report_get_seeded",
              response: .fixture("report_get_seeded.json")) { client in
            try expectDecoded(try await client.report(id: "r_cb24d96d31d7"), ReportRecord.self, "report_get_seeded.json")
        },
        route("reportMarkdown", "GET", "/api/games/\(game)/export/report.md", accept: "*/*", capture: "export_report_md",
              response: .fixture("export_report_md.md", contentType: "text/markdown; charset=utf-8")) { client in
            let markdown = try await client.reportMarkdown(gameID: game)
            #expect(markdown == (try Fixture.text("export_report_md.md")))
        },
        route("downloadReportMarkdown", "GET", "/api/games/\(game)/export/report.md", query: "report_id=r_cb24d96d31d7&download=1",
              accept: "*/*", capture: "export_report_md_by_id_download",
              response: .fixture("export_report_md.md", headers: attachment("scouting_report_test-team-a_2026-11-07.md", type: "text/markdown; charset=utf-8"))) { client in
            let file = try await client.downloadReportMarkdown(gameID: game, reportID: "r_cb24d96d31d7")
            try expectDownload(file, filename: "scouting_report_test-team-a_2026-11-07.md", fixture: "export_report_md.md", contentType: "text/markdown; charset=utf-8")
        },
    ]

    static let rosters: [RouteCase] = [
        route("rosters", "GET", "/api/games/\(game)/rosters", capture: "rosters_get", response: .fixture("rosters_get.json")) { client in
            try expectDecoded(try await client.rosters(gameID: game), GameRosters.self, "rosters_get.json")
        },
        route("roster", "GET", "/api/games/\(game)/rosters/other", capture: "roster_get_other",
              response: .fixture("roster_get_other.json")) { client in
            try expectDecoded(try await client.roster(gameID: game, side: .other), Roster.self, "roster_get_other.json")
        },
        route("replaceRoster", "PUT", "/api/games/\(game)/rosters/scouted", contentType: "application/json",
              body: .json(#"{"players":[{"fastscout_name":null,"first_name":"Test","grade":null,"height":null,"id":"p_fixture01","jersey":"1","last_name":"Player 1","notes":null,"position":"G"},{"fastscout_name":null,"first_name":"Test","grade":null,"height":null,"id":"p_fixture02","jersey":"02","last_name":"Player 2","notes":"Fixture note","position":"C"},{"fastscout_name":null,"first_name":"Test","grade":null,"height":null,"jersey":"4","last_name":"Player 4","notes":null,"position":null}],"team_name":"Test Team A"}"#),
              capture: "roster_replace", response: .fixture("roster_replace.json")) { client in
            let body = RosterReplace(teamName: "Test Team A", players: [
                RosterPlayerInput(id: "p_fixture01", jersey: "1", firstName: "Test", lastName: "Player 1", position: "G"),
                RosterPlayerInput(id: "p_fixture02", jersey: "02", firstName: "Test", lastName: "Player 2", position: "C", notes: "Fixture note"),
                RosterPlayerInput(jersey: "4", firstName: "Test", lastName: "Player 4"),
            ])
            try expectDecoded(try await client.replaceRoster(gameID: game, side: .scouted, body), Roster.self, "roster_replace.json")
        },
        route("importRoster", "POST", "/api/games/\(game)/rosters/other/import", contentType: "multipart/form-data; boundary=",
              body: .multipart(filename: "roster_other.csv", fileContentType: "text/csv",
                               fileData: (try? Fixture.data("request_roster_other.csv")) ?? Data(), fields: ["mode": "replace"]),
              capture: "roster_import", response: .fixture("roster_import.json")) { client in
            let result = try await client.importRoster(
                gameID: game, side: .other, fileData: try Fixture.data("request_roster_other.csv"),
                filename: "roster_other.csv", mode: .replace)
            try expectDecoded(result, RosterImportResult.self, "roster_import.json")
        },
        route("addPlayer", "POST", "/api/games/\(game)/rosters/scouted/players", contentType: "application/json",
              body: .json(#"{"fastscout_name":null,"first_name":"Test","grade":"12","height":"6'0\"","jersey":"1","last_name":"Player 1","notes":null,"position":"G"}"#),
              capture: "roster_add_player", response: .fixture("roster_add_player.json")) { client in
            let player = RosterPlayerInput(jersey: "1", firstName: "Test", lastName: "Player 1", position: "G", grade: "12", height: "6'0\"")
            try expectDecoded(try await client.addPlayer(gameID: game, side: .scouted, player), Roster.self, "roster_add_player.json")
        },
        route("updatePlayer", "PATCH", "/api/games/\(game)/rosters/scouted/players/p_fixture02", contentType: "application/json",
              body: .json(#"{"fastscout_name":"Test Player 2","notes":"Fixture note","position":"C"}"#),
              capture: "roster_patch_player", response: .fixture("roster_patch_player.json")) { client in
            let patch = RosterPlayerPatch(position: .value("C"), notes: .value("Fixture note"), fastscoutName: .value("Test Player 2"))
            let roster = try await client.updatePlayer(gameID: game, side: .scouted, playerID: "p_fixture02", patch)
            try expectDecoded(roster, Roster.self, "roster_patch_player.json")
        },
        route("deletePlayer", "DELETE", "/api/games/\(game)/rosters/scouted/players/p_7a69520b3109", capture: "roster_delete_player",
              response: .fixture("roster_delete_player.json")) { client in
            let roster = try await client.deletePlayer(gameID: game, side: .scouted, playerID: "p_7a69520b3109")
            try expectDecoded(roster, Roster.self, "roster_delete_player.json")
        },
        route("deletePlayerWithClientChosenID", "DELETE", "/api/games/\(game)/rosters/other/players/custom%20id%2F1",
              response: .fixture("roster_delete_player.json")) { client in
            _ = try await client.deletePlayer(gameID: game, side: .other, playerID: "custom id/1")
        },
        route("downloadRosterTemplate", "GET", "/api/roster-template.csv", accept: "*/*", capture: "roster_template",
              response: .fixture("roster_template.csv", headers: attachment("roster-template.csv", type: "text/csv; charset=utf-8"))) { client in
            let file = try await client.downloadRosterTemplate()
            try expectDownload(file, filename: "roster-template.csv", fixture: "roster_template.csv", contentType: "text/csv; charset=utf-8")
        },
    ]

    static let tracks: [RouteCase] = [
        route("tracks", "GET", "/api/games/\(game)/tracks", capture: "tracks", response: .fixture("tracks.json")) { client in
            try expectDecoded(try await client.tracks(gameID: game), TrackState.self, "tracks.json")
        },
        route("setTrackOverride", "PUT", "/api/games/\(game)/tracks/7", contentType: "application/json",
              body: .json(#"{"ignore":false,"player_id":"p_fixture05","side":"scouted"}"#),
              capture: "track_override_assign", response: .fixture("track_override_assign.json")) { client in
            let override = try await client.setTrackOverride(gameID: game, trackID: 7, TrackOverrideBody(playerID: "p_fixture05", side: .scouted))
            try expectDecoded(override, TrackOverride.self, "track_override_assign.json")
        },
        route("deleteTrackOverride", "DELETE", "/api/games/\(game)/tracks/12", capture: "track_override_delete",
              response: .empty(204)) { client in
            try await client.deleteTrackOverride(gameID: game, trackID: 12)
        },
    ]

    static let exports: [RouteCase] = [
        route("fastScoutText", "GET", "/api/games/\(game)/export/fastscout.txt", query: "side=scouted", accept: "*/*",
              capture: "export_fastscout_txt", response: .fixture("export_fastscout_txt.txt", contentType: "text/plain; charset=utf-8")) { client in
            let block = try await client.fastScoutText(gameID: game)
            #expect(block == (try Fixture.text("export_fastscout_txt.txt")))
        },
        route("downloadFastScoutText", "GET", "/api/games/\(game)/export/fastscout.txt", query: "side=scouted&download=1", accept: "*/*",
              capture: "export_fastscout_txt_download",
              response: .fixture("export_fastscout_txt.txt", headers: attachment("fastscout_test-team-a_2026-11-07.txt", type: "text/plain; charset=utf-8"))) { client in
            let file = try await client.downloadFastScoutText(gameID: game)
            try expectDownload(file, filename: "fastscout_test-team-a_2026-11-07.txt", fixture: "export_fastscout_txt.txt", contentType: "text/plain; charset=utf-8")
        },
        route("fastScoutNotes", "GET", "/api/games/\(game)/export/fastscout-notes", query: "side=other",
              response: .fixture("export_fastscout_notes_other.json")) { client in
            try expectDecoded(try await client.fastScoutNotes(gameID: game, side: .other), FastScoutNotes.self, "export_fastscout_notes_other.json")
        },
        route("fastScoutTables", "GET", "/api/export/fastscout/tables", capture: "fastscout_tables",
              response: .fixture("fastscout_tables.json")) { client in
            let tables = try await client.fastScoutTables()
            #expect(tables == ["box", "zones", "plays", "defense"])
        },
        route("downloadFastScoutCSV", "GET", "/api/games/\(game)/export/fastscout.csv", query: "side=other&table=box&download=1", accept: "*/*",
              capture: "export_fastscout_csv_table_download",
              response: .fixture("export_fastscout_csv_table_box.csv", headers: attachment("fastscout_box_test-team-b_2026-11-07.csv", type: "text/csv; charset=utf-8"))) { client in
            let file = try await client.downloadFastScoutCSV(gameID: game, side: .other, table: "box")
            try expectDownload(file, filename: "fastscout_box_test-team-b_2026-11-07.csv", fixture: "export_fastscout_csv_table_box.csv", contentType: "text/csv; charset=utf-8")
        },
        route("downloadFastScoutCSVDefaultTable", "GET", "/api/games/\(game)/export/fastscout.csv", query: "side=scouted&download=1", accept: "*/*",
              response: .fixture("export_fastscout_csv.csv", headers: attachment("fastscout_test-team-a_2026-11-07.csv", type: "text/csv; charset=utf-8"))) { client in
            let file = try await client.downloadFastScoutCSV(gameID: game, table: "")
            try expectDownload(file, filename: "fastscout_test-team-a_2026-11-07.csv", fixture: "export_fastscout_csv.csv", contentType: "text/csv; charset=utf-8")
        },
        route("downloadTimelineCSV", "GET", "/api/games/\(game)/export/timeline.csv", query: "download=1", accept: "*/*",
              capture: "export_timeline_csv_download",
              response: .fixture("export_timeline_csv.csv", headers: attachment("timeline_test-team-a_2026-11-07.csv", type: "text/csv; charset=utf-8"))) { client in
            let file = try await client.downloadTimelineCSV(gameID: game)
            try expectDownload(file, filename: "timeline_test-team-a_2026-11-07.csv", fixture: "export_timeline_csv.csv", contentType: "text/csv; charset=utf-8")
        },
        route("downloadAnalysisJSON", "GET", "/api/games/\(game)/export/analysis.json", query: "download=1", accept: "*/*",
              capture: "export_analysis_json_download",
              response: .fixture("export_analysis_json.json", headers: attachment("analysis_test-team-a_2026-11-07.json", type: "application/json"))) { client in
            let file = try await client.downloadAnalysisJSON(gameID: game)
            try expectDownload(file, filename: "analysis_test-team-a_2026-11-07.json", fixture: "export_analysis_json.json", contentType: "application/json")
        },
    ]
}
