import Foundation
import Testing
@testable import BasketballScout

/// Every JSON fixture decodes into its model (08 index → 01 §4.10), error bodies into `ErrorEnvelope`, and
/// survives an encode/decode round trip.
nonisolated struct FixtureDecodingTests {
    @Test func manifestLoadsAndListsEveryJSONFixture() throws {
        #expect(FixtureCatalog.manifest.count == 293)
        let inManifest = Set(FixtureCatalog.jsonEntries.compactMap(\.file))
        let inBundle = Set(Fixture.names(withExtension: "json")).subtracting(["_manifest.json"])
        #expect(inBundle.count == 255)
        #expect(inManifest == inBundle)
    }

    @Test func everyJSONFixtureHasAModel() {
        let unmapped = FixtureCatalog.jsonEntries.filter {
            FixtureModel.model(method: $0.method, endpoint: $0.endpoint, status: $0.status) == nil
        }
        #expect(unmapped.isEmpty, "No model for: \(unmapped.map(\.description))")
    }

    @Test(arguments: FixtureCatalog.jsonEntries)
    func decodesAndRoundTrips(_ entry: ManifestEntry) throws {
        let file = try #require(entry.file)
        let model = try #require(FixtureModel.model(method: entry.method, endpoint: entry.endpoint, status: entry.status))
        let result = try model.roundTrip(Fixture.data(file))
        #expect(result.equal, "\(file) as \(result.typeName) changed in an encode/decode round trip")
    }

    @Test func errorFixturesAreExactlyTheErrorStatuses() {
        let errors = FixtureCatalog.jsonEntries.filter { $0.status >= 400 }.compactMap(\.file)
        #expect(errors.count == 107)
        #expect(errors.allSatisfy { $0.hasPrefix("err_") })
        let others = FixtureCatalog.jsonEntries.filter { $0.status < 400 }.compactMap(\.file)
        #expect(others.allSatisfy { !$0.hasPrefix("err_") })
    }

    // MARK: - Spot checks per model

    @Test func game() throws {
        let game = try Fixture.decode(Game.self, "game_create.json")
        #expect(game.id == "g_e934f8c21058")
        #expect(game.title == "")
        #expect(game.scoutedTeam == "Test Team A")
        #expect(game.otherTeam == "Test Team B")
        #expect(game.gameDate == GameDate(year: 2026, month: 11, day: 7))
        #expect(game.location == "Test Gym")
        #expect(game.level == "Varsity")
        #expect(game.scoutedColor == "dark")
        #expect(game.teamIDMap.isEmpty)
        #expect(game.status == .draft)
        #expect(game.videoFilename == nil && game.videoSize == nil && game.videoURL == nil)
        #expect(!game.hasVideo && !game.hasAnnotatedVideo && !game.hasAnalysis && !game.hasTracking)
        #expect(game.calibration == nil && game.latestJobID == nil && game.error == nil)
        #expect(game.createdAt == ScoutTimestamp.date(from: "2026-11-11T19:57:32.437229Z"))
        #expect(game.displayTitle == "Test Team A vs Test Team B")
    }

    @Test func gameWithCalibrationTeamMapAndError() throws {
        let calibrated = try Fixture.decode(Game.self, "game_with_calibration.json")
        let calibration = try #require(calibrated.calibration)
        #expect(calibration.points.count == 4)
        #expect(calibration.points[0] == CalibrationPoint(landmark: "left_baseline_near_corner", px: XY(x: 40, y: 330)))
        #expect(calibration.matrix[1][0] == -4.501271471773479e-17)
        #expect(calibration.matrix[2][2] == 1.0)
        #expect(calibration.frameT == nil && calibration.videoWidth == nil)

        let mapped = try Fixture.decode(Game.self, "game_patch_team_id_map.json")
        #expect(mapped.teamIDMap == ["0": .scouted, "1": .other])
        #expect(mapped.teamIDsBySide == [0: .scouted, 1: .other])

        let failed = try Fixture.decode(Game.self, "game_failed.json")
        #expect(failed.status == .failed)
        #expect(failed.error?.code == ErrorCode.videoMissing)
        #expect(failed.error?.retryable == false)
        #expect(failed.displayTitle == "Test Team C")

        let link = try Fixture.decode(Game.self, "game_link_ready.json")
        #expect(link.videoURL == "https://example.com/films/test-film.mp4")
        #expect(link.videoSize == nil && !link.hasVideo)
    }

    @Test func gamesLists() throws {
        #expect(try Fixture.decode([Game].self, "games_list.json").count == 3)
        #expect(try Fixture.decode([Game].self, "games_list_empty.json").isEmpty)
        #expect(try Fixture.decode([Game].self, "games_list_final.json").count == 2)
    }

    @Test func jobs() throws {
        let queued = try Fixture.decode(Job.self, "job_link_1_queued_queued.json")
        #expect(queued.kind == .analyze && queued.status == .queued && queued.stage == .queued)
        #expect(queued.progress == 0 && queued.message == "Waiting for a worker")
        #expect(queued.params.isEmpty && queued.leaseExpiresAt == nil && queued.startedAt == nil)

        let lateCancel = try Fixture.decode(Job.self, "job_late_cancel_2_succeeded_done.json")
        #expect(lateCancel.status == .succeeded && lateCancel.stage == .done && lateCancel.cancelRequested)
        #expect(lateCancel.warnings == ["Cancelled after the new GPU results were in place: the analysis was finished."])
        #expect(lateCancel.leaseExpiresAt == 1794427806.3943439)
        #expect(lateCancel.processor == "mock" && lateCancel.externalID == "mock:j_6d97c2b25cbf")

        let failed = try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")
        #expect(failed.status == .failed && failed.stage == .preparing && failed.message == "No video")
        #expect(failed.error?.title == "No video")

        let reanalyze = try Fixture.decode(Job.self, "job_create_reanalyze_2.json")
        #expect(reanalyze.kind == .reanalyze && reanalyze.processor == nil)
        #expect(reanalyze.params == ["report": .bool(false)])

        let list = try Fixture.decode([Job].self, "jobs_list_game1.json")
        #expect(list.count == 6)
        #expect(list.map(\.status) == [.succeeded, .cancelled, .succeeded, .cancelled, .succeeded, .succeeded])
    }

    @Test func uploadsAndFilmResults() throws {
        let created = try Fixture.decode(UploadSession.self, "upload_create.json")
        #expect(created.id == "u_4b596795629f" && created.status == .open)
        #expect(created.size == 41284 && created.received == 0 && created.chunkSize == 16_777_216)
        #expect(created.nextChunkLength == 41284)

        let partial = try Fixture.decode(UploadSession.self, "upload_get_partial.json")
        #expect(partial.received == 20000 && partial.remaining == 21284)
        #expect(try Fixture.decode(UploadSession.self, "upload_get_aborted.json").status == .aborted)
        #expect(try Fixture.decode(UploadSession.self, "upload_get_complete.json").status == .complete)
        #expect(try Fixture.decode(UploadSession.self, "upload_create_game3.json").filename == "test-film.mp4")
        #expect(try Fixture.decode(UploadSession.self, "upload_create_large.json").size == 41_943_040)

        let complete = try Fixture.decode(FilmResult.self, "upload_complete.json")
        #expect(complete.game.status == .queued && complete.game.hasVideo)
        #expect(complete.job?.kind == .analyze && complete.job?.params.isEmpty == true)
        #expect(complete.game.latestJobID == complete.job?.id)

        let noAutoStart = try Fixture.decode(FilmResult.self, "video_url_set_no_autostart.json")
        #expect(noAutoStart.job == nil && noAutoStart.game.status == .uploaded)
        #expect(noAutoStart.game.videoFilename == "Test Team D game.mp4")
        #expect(noAutoStart.game.videoURL == "https://example.com/films/Test%20Team%20D%20game.mp4?dl=1")
    }

    @Test func errorEnvelopes() throws {
        let conflict = try Fixture.decode(ErrorEnvelope.self, "err_409_chunk_wrong_offset.json")
        #expect(conflict.error.code == ErrorCode.conflict)
        #expect(conflict.error.hint == "Resume from upload.received.")
        #expect(conflict.upload?.received == 20000)

        let notFound = try Fixture.decode(ErrorEnvelope.self, "err_404_unknown_game.json")
        #expect(notFound.upload == nil)
        #expect(notFound.error == ErrorInfo(code: "NOT_FOUND", title: "Not found", message: "Game 'g_000000000000' not found."))

        let throttled = try Fixture.decode(ErrorEnvelope.self, "err_429_auth_throttled.json")
        #expect(throttled.error.code == ErrorCode.authThrottled && throttled.error.retryable == false)

        let validation = try Fixture.decode(ErrorEnvelope.self, "err_422_create_game_too_long.json")
        #expect(validation.error.code == ErrorCode.validationFailed)
        #expect(validation.error.displayMessage == "Some fields are invalid. " + (validation.error.detail ?? ""))
        #expect(validation.error.detail?.contains("scouted_team: String should have at most 120 characters") == true)

        let methodNotAllowed = try Fixture.decode(ErrorEnvelope.self, "err_405_method_not_allowed.json")
        #expect(methodNotAllowed.error.code == ErrorCode.validationFailed)
        #expect(methodNotAllowed.error.displayMessage == "Method Not Allowed")

        let queueHint = try Fixture.decode(ErrorEnvelope.self, "err_503_report_not_configured.json")
        #expect(queueHint.error.code == ErrorCode.reportNotConfigured)
    }

    @Test func rosters() throws {
        let rosters = try Fixture.decode(GameRosters.self, "rosters_get.json")
        #expect(rosters[.scouted]?.side == .scouted && rosters[.other]?.side == .other)
        #expect(rosters[.unknown("home")] == nil)

        let empty = try Fixture.decode(GameRosters.self, "rosters_get_empty.json")
        #expect(empty.scouted.players.isEmpty && empty.scouted.isNeverSaved && empty.scouted.teamName == "Test Team A")

        let added = try Fixture.decode(Roster.self, "roster_add_player_2.json")
        let player = try #require(added.player(id: "p_fixture02"))
        #expect(player.jersey == "02")
        #expect(player.name == "Test Player 2")

        let imported = try Fixture.decode(RosterImportResult.self, "roster_import.json")
        #expect(imported.imported == 4)
        #expect(imported.skippedRows == [RosterImportResult.SkippedRow(row: 5, reason: "invalid jersey number 'abc'")])
        #expect(imported.skippedRows.first?.displayText == "Row 5: invalid jersey number 'abc'")
        #expect(imported.detectedColumns["first_name"] == "First Name")
        #expect(imported.columnsUsed.first?.label == "Jersey")
        let blank = try #require(imported.roster.players.first { $0.jersey == "14" })
        #expect(blank.firstName == "" && blank.lastName == "" && blank.name == "")
    }

    @Test func tracks() throws {
        let state = try Fixture.decode(TrackState.self, "tracks_with_overrides.json")
        #expect(state.assignments.count == 15)
        #expect(state.overrides == [
            TrackOverride(trackID: 7, playerID: "p_fixture05", side: .scouted, ignore: false),
            TrackOverride(trackID: 12, playerID: nil, side: .other, ignore: false),
            TrackOverride(trackID: 13, playerID: nil, side: nil, ignore: true),
        ])
        let first = try #require(state.assignments.first)
        #expect(first.trackID == 3 && first.teamID == 0 && first.side == .scouted && first.role == "player")
        #expect(first.votes == ["14": 138.95, "4": 4.39, "74": 3.48, "1": 1.76, "11": 0.84])
        #expect(first.method == .unrostered)
        let referee = try #require(state.assignments.first { $0.role == "referee" })
        #expect(referee.method == .noReads && referee.side == nil && referee.votes.isEmpty && referee.matchScore == 0)

        #expect(try Fixture.decode(TrackState.self, "tracks_empty.json") == TrackState())
        #expect(try Fixture.decode(TrackOverride.self, "track_override_unassign.json").trackID == 12)
    }

    @Test func calibrationAndLandmarks() throws {
        let calibration = try Fixture.decode(CourtCalibration.self, "calibration_put.json")
        #expect(calibration.points.count == 7)
        #expect(calibration.points.last?.px == XY(x: 321.5, y: 183.25))
        #expect(calibration.reprojectionErrorFt == 1.486)
        #expect(calibration.frameT == 1.5 && calibration.videoWidth == 640 && calibration.videoHeight == 360)
        #expect(calibration.matrix.count == 3 && calibration.matrix.allSatisfy { $0.count == 3 })

        let minimal = try Fixture.decode(CourtCalibration.self, "calibration_put_minimal.json")
        #expect(minimal.reprojectionErrorFt == 0)

        let landmarks = try Fixture.decode(CourtLandmarks.self, "court_landmarks.json")
        #expect(landmarks.court == .nfhs)
        #expect(landmarks.landmarks.map(\.name) == CourtLandmarks.documentedOrder)
        #expect(landmarks["left_three_corner_near"]?.point == XY(x: 0, y: 5.25))
        #expect(landmarks["center_circle_far"]?.point == XY(x: 42, y: 31))
        #expect(landmarks.grouped.map(\.group) == [.leftEnd, .rightEnd, .middle])
        #expect(landmarks.grouped.map(\.landmarks.count) == [10, 10, 5])
    }

    @Test func reports() throws {
        let record = try Fixture.decode(ReportRecord.self, "report_get_seeded.json")
        #expect(record.id == "r_cb24d96d31d7" && record.model == "claude-opus-5-5")
        #expect(record.coachFocus == "We play a 2-3 zone" && record.stopReason == "end_turn" && !record.wasCutOff)
        #expect(record.usage == ["input_tokens": 12000, "output_tokens": 3500, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0])
        #expect(record.report.keyPlayers.map(\.threatLevel) == [.high, .medium])
        #expect(record.report.keyPlayers.first?.name == "Test Player 2")
        #expect(record.report.playTendencies.first?.playType == "Transition")
        #expect(record.report.summaryParagraphs.count == 1)
        #expect(record.markdown.hasPrefix("# Scouting Report: Test Team A"))

        #expect(try Fixture.decode([ReportRecord].self, "reports_list_seeded.json").count == 1)
        #expect(try Fixture.decode([ReportRecord].self, "reports_list_empty.json").isEmpty)
    }

    @Test func healthAndExports() throws {
        let health = try Fixture.decode(HealthStatus.self, "health.json")
        #expect(health.status == .ok && health.version == "0.1.0" && health.processor == "mock")
        #expect(health.queueBackend == "sqlite" && health.queueOK && health.authEnabled)
        #expect(health.workerLastSeenS == 26.1 && health.maxUploadBytes == 12_884_901_888)

        let degraded = try Fixture.decode(HealthStatus.self, "health_degraded.json")
        #expect(degraded.status == .degraded && degraded.workerLastSeenS == 120.4)

        #expect(try Fixture.decode(HealthLive.self, "health_live.json").isOK)

        let notes = try Fixture.decode(FastScoutNotes.self, "export_fastscout_notes.json")
        #expect(notes.warnings.count == 6)
        #expect(notes.teamNumbers.hasPrefix("Test Team A: team numbers to type in by hand"))
        #expect(notes.teamNumbers.components(separatedBy: "\n").count == 7)

        #expect(try Fixture.decode([String].self, "fastscout_tables.json") == ["box", "zones", "plays", "defense"])
    }

    @Test func analysis() throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        #expect(analysis.schemaVersion == "1.0" && analysis.gameID == "g_e934f8c21058")
        #expect(analysis.generatedAt == ScoutTimestamp.date(from: "2026-11-11T20:02:15.513136Z"))
        #expect(analysis.video.fps == 30 && analysis.video.width == 1920 && analysis.video.durationS == 600)
        #expect(analysis.pipeline.name == "synthetic" && analysis.pipeline.options["seed"]?.intValue == 25151)
        #expect(analysis.teams.map(\.side) == [.scouted, .other])
        #expect(analysis.teams[0].colorRGB == RGB(red: 24, green: 34, blue: 76))
        #expect(analysis.timeline.count == 310)
        #expect(analysis.possessions.count == 47)
        #expect(analysis.plays.count == 78)
        #expect(analysis.shots.count == 47)
        #expect(analysis.boxScores.map(\.side) == [.scouted, .other])
        #expect(analysis.trackAssignments.count == 15)
        #expect(analysis.dataQuality.coordMode == .court && analysis.dataQuality.homographyAvailable)
        #expect(analysis.dataQuality.ballCoverage == 0.98 && analysis.dataQuality.warnings.isEmpty)

        let first = try #require(analysis.timeline.first)
        #expect(first.type == .periodStart && first.side == nil && first.zone == nil && first.player == nil)
        let shot = try #require(analysis.timeline.first { $0.id == "ev_00013" })
        #expect(shot.type == .shotMade && shot.points == 2 && shot.zone == .paint && shot.isThree == false)
        #expect(shot.player?.label == "#5 Test Player 2" && shot.courtXY == XY(x: 77.5, y: 29))
        #expect(shot.t == 25.566666666666666 && shot.scoreScouted == 2)

        let box = try #require(analysis.boxScore(.scouted))
        #expect(box.totals.pts == 25 && box.totals.reb == 13 && box.totals.fgPct == 0.478)
        #expect(box.teamUnattributed.player.label == "Team" && box.teamUnattributed.minutesEst == nil)
        #expect(box.totals.zones.three == ShootingSplit(made: 3, attempts: 7))
        #expect(box.pointsPerPossession == 1.042 && box.possessions == 24)

        let unmatched = try Fixture.decode(GameAnalysis.self, "analysis_unmatched.json")
        #expect(unmatched.dataQuality.jerseyMatchRate == 0)
        #expect(unmatched.dataQuality.warnings == [PipelineWarning(
            code: "LOW_JERSEY_MATCH",
            message: "Only 0% of player time was matched to roster jerseys: check the roster numbers or assign players to tracks on the roster page.",
            severity: .warning)])
        #expect(unmatched.dataQuality.unmatchedJerseys.first == "scouted:#0")

        // export/analysis.json is the same analysis, indented (06 §1.3).
        #expect(try Fixture.decode(GameAnalysis.self, "export_analysis_json.json") == analysis)
    }

    @Test func playAttributesKeepTheirKeys() throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let zone = try #require(analysis.plays.first { $0.type == .zoneDefense })
        #expect(zone.category == .defense && zone.players.isEmpty)
        #expect(zone.zoneShape != nil)
        #expect(zone.attrs["follow_score"]?.doubleValue != nil)
        let pickAndRoll = try #require(analysis.plays.first { $0.type == .pickAndRoll })
        #expect(pickAndRoll.attrs["roll_or_pop"]?.stringValue != nil)
        #expect(pickAndRoll.orderedPlayers.map(\.role) == ["ball_handler", "screener"])
        let postUp = try #require(analysis.plays.first { $0.type == .postUp })
        #expect(postUp.orderedPlayers.map(\.role) == ["post_player", "passer", "defender"])
        let withAlso = analysis.plays.first { $0.attrs["also"] != nil }
        #expect(withAlso?.attrs["also"]?.arrayValue?.allSatisfy { $0.stringValue != nil } == true)
    }

    @Test func openAPIDocumentDecodesAsJSONValue() throws {
        let document = try Fixture.decode(JSONValue.self, "openapi.json")
        #expect(document["info"]?["title"]?.stringValue == "Basketball Scout")
        #expect(document["paths"]?.objectValue?.count == 34)
        let gameCreate = document["components"]?["schemas"]?["GameCreate"]?["properties"]?.objectValue
        #expect(gameCreate?.keys.contains("scouted_team") == true)
    }
}
