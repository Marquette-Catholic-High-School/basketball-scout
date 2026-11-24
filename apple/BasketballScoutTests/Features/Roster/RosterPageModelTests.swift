import Foundation
import Testing
@testable import BasketballScout

/// The roster page against a stubbed server (05 §7.2–§7.4, §7.13; 09 D1 #3, #7, R37): loading, saving,
/// importing, the template, the re-run, refetching without losing edits, one write per side.
@MainActor
struct RosterPageModelTests {
    private let gamePath = RosterTestHarness.gamePath

    // MARK: - Loading

    @Test func openingLoadsTheGameRostersLatestJobAndTracks() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        #expect(model.hasLoaded)
        #expect(model.loadError == nil)
        #expect(model.game?.hasTracking == true)
        #expect(model.editors.scouted.rows.count == 5)
        #expect(model.editors.other.teamName == "Test Team B")
        #expect(!model.hasUnsavedChanges)
        #expect(model.tracks.isShown)
        #expect(model.tracks.assignments.count == 15)
        #expect(model.tracks.overrides.keys.sorted() == [7, 13])
        #expect(model.sections == [.roster(.scouted), .roster(.other), .tracks])
        #expect(!model.isLocked)
        #expect(model.showsDemoNotice)  // health.json: the mock processor
        #expect(Set(h.routeLog) == [
            "GET \(gamePath)", "GET \(gamePath)/rosters", "GET /api/jobs/j_ffaf913e4144", "GET \(gamePath)/tracks",
        ])
        #expect(h.routeLog.count == 4)
    }

    @Test func aGameWithoutAnAnalysisHasNoAssignments() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, .fixture("game_get.json"))
        h.server.on("GET", "\(gamePath)/rosters", .fixture("rosters_get_empty.json"))
        await h.model.refresh()
        #expect(h.model.hasLoaded)
        #expect(h.model.sections == [.roster(.scouted), .roster(.other)])
        #expect(h.model.editors.scouted.rows.isEmpty)
        #expect(h.requests("GET", "\(gamePath)/tracks").isEmpty)
    }

    @Test func aRosterWithoutATeamNameShowsTheGamesName() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        var rosters = try RosterTestHarness.finalRosters()
        rosters.other.teamName = ""
        h.serveReadyGame()
        h.server.on("GET", "\(gamePath)/rosters", try RosterTestHarness.reply(rosters))
        await h.model.refresh()
        #expect(h.model.editors.other.teamName == "Test Team B")
        #expect(!h.model.editors.other.isDirty)
    }

    @Test func aFailedLoadIsShownAndTriedAgain() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.server.on("GET", gamePath, RosterTestHarness.error(404, code: "NOT_FOUND", title: "Not found", message: "Game 'g_e934f8c21058' not found."))
        h.server.on("GET", "\(gamePath)/rosters", .fixture("rosters_get_final.json"))
        await h.model.refresh()
        #expect(!h.model.hasLoaded)
        #expect(h.model.loadError?.message == "Game 'g_e934f8c21058' not found.")
        h.serveReadyGame()
        await h.model.refresh()
        #expect(h.model.hasLoaded)
        #expect(h.model.loadError == nil)
    }

    @Test func comingBackMomentsLaterReadsNothingButTheForegroundDoes() async throws {
        let clock = SessionClock()
        let h = try await RosterTestHarness(now: clock.reader)
        defer { h.cleanUp() }
        h.serveReadyGame()
        let rosters = "\(gamePath)/rosters"
        await h.model.run(generation: 0)
        #expect(h.requests("GET", rosters).count == 1)
        await h.model.run(generation: 0)
        #expect(h.requests("GET", rosters).count == 1)
        await h.model.run(generation: 1)
        #expect(h.requests("GET", rosters).count == 2)
        clock.advance(by: RosterPageModel.refetchInterval + 1)
        await h.model.run(generation: 1)
        #expect(h.requests("GET", rosters).count == 3)
    }

    // MARK: - Refetching (09 R37)

    @Test func aRefetchKeepsUnsavedEditsAndOffersTheNewerServerCopy() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        let first = try #require(model.editors.scouted.rows.first?.id)
        model.setField(.lastName, row: first, side: .scouted, to: "Player 99")
        var newer = try RosterTestHarness.finalRosters()
        newer.scouted.players.removeLast()
        newer.scouted.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        newer.other.players.removeLast()
        newer.other.updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        h.server.on("GET", "\(gamePath)/rosters", try RosterTestHarness.reply(newer))
        await model.refresh()
        #expect(model.editors.scouted.rows.count == 5)
        #expect(model.editors.scouted.rows.first?.lastName == "Player 99")
        #expect(model.editors.scouted.newerServerCopy == newer.scouted)
        // An editor without unsaved changes shows the server's roster.
        #expect(model.editors.other.rows.count == 4)
        #expect(model.editors.other.newerServerCopy == nil)
        model.useServerCopy(.scouted)
        #expect(model.editors.scouted.rows.count == 4)
        #expect(!model.editors.scouted.isDirty)
    }

    // MARK: - Saving (05 §7.2, §7.4)

    @Test func savingSendsTheWebsBodyAndShowsTheServersAnswer() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        let row = model.addRow(.scouted)
        model.setField(.jersey, row: row, side: .scouted, to: " #7 ")
        model.setField(.firstName, row: row, side: .scouted, to: " Test ")
        model.setField(.lastName, row: row, side: .scouted, to: "Player 11 ")
        model.setTeamName(" Test Team A ", side: .scouted)
        #expect(model.hasUnsavedChanges)
        var saved = try RosterTestHarness.finalRosters().scouted
        saved.players.append(RosterPlayer(id: "p_000000000011", jersey: "7", firstName: "Test", lastName: "Player 11"))
        h.server.on("PUT", "\(gamePath)/rosters/scouted", try RosterTestHarness.reply(saved))

        #expect(await model.saveRoster(.scouted))

        let put = try #require(h.requests("PUT", "\(gamePath)/rosters/scouted").first)
        #expect(put.header("Content-Type")?.hasPrefix("application/json") == true)
        let body = try RosterTestHarness.json(put)
        #expect(body["team_name"] as? String == "Test Team A")
        let players = try #require(body["players"] as? [[String: Any]])
        #expect(players.count == 6)
        #expect(players.first?["id"] as? String == "p_fixture01")
        let added = try #require(players.last)
        #expect(added["id"] == nil)
        #expect(added["jersey"] as? String == "7")
        #expect(added["first_name"] as? String == "Test")
        #expect(added["last_name"] as? String == "Player 11")
        #expect(added["position"] is NSNull)
        #expect(added["fastscout_name"] is NSNull)
        #expect(added.keys.sorted() == ["fastscout_name", "first_name", "grade", "height", "jersey", "last_name", "notes", "position"])

        #expect(!model.hasUnsavedChanges)
        #expect(model.editors.scouted.rows.last?.serverID == "p_000000000011")
        #expect(h.toasts.current?.text == "Roster saved")
        #expect(model.showsRerunBanner)
        // After the save: the game and the tracks are read again.
        #expect(h.requests("GET", gamePath).count == 2)
        #expect(h.requests("GET", "\(gamePath)/tracks").count == 2)
    }

    @Test func anInvalidJerseyIsRefusedBeforeSending() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        let row = model.addRow(.other)
        model.setField(.jersey, row: row, side: .other, to: "123")
        model.setField(.firstName, row: row, side: .other, to: "Test")
        #expect(await !model.saveRoster(.other))
        #expect(model.editors.other.error?.title == "Check the roster")
        #expect(model.editors.other.error?.message == "Row 6: a jersey number is one or two digits (0-99), not \"123\".")
        #expect(model.editors.other.invalidRowID == row)
        #expect(h.requests("PUT", "\(gamePath)/rosters/other").isEmpty)
        model.setField(.jersey, row: row, side: .other, to: "12")
        #expect(model.editors.other.invalidRowID == nil)
    }

    @Test func aRefusedSaveShowsTheServersErrorAndKeepsTheEdits() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.server.on("PUT", "\(gamePath)/rosters/other", .fixture("err_422_roster_replace_duplicate_ids.json", status: 422))
        h.model.setTeamName("Test Team B (JV)", side: .other)
        #expect(await !h.model.saveRoster(.other))
        #expect(h.model.editors.other.error?.title == "Invalid input")
        #expect(h.model.editors.other.error?.message == "Some fields are invalid. players: two players have the same id")
        #expect(h.model.editors.other.isDirty)
        #expect(!h.model.showsRerunBanner)
    }

    @Test func withoutGPUResultsTheBannerStaysHidden() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.server.on("GET", gamePath, .fixture("game_get.json"))
        h.server.on("PUT", "\(gamePath)/rosters/scouted", .fixture("roster_replace.json"))
        #expect(await h.model.saveRoster(.scouted))
        #expect(!h.model.showsRerunBanner)
        #expect(h.model.game?.hasTracking == false)
    }

    @Test func writesOfOneSideWaitForEachOther() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        let path = "\(gamePath)/rosters/scouted"
        let body = try ScoutJSON.encode(try RosterTestHarness.finalRosters().scouted)
        let hold = HeldReply { .json(200, body) }
        h.server.on("PUT", path, .held(hold), .json(200, body))
        let first = Task { await model.saveRoster(.scouted) }
        try await waitUntil("the first save to be sent") { hold.isWaiting }
        let second = Task { await model.saveRoster(.scouted) }
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.requests("PUT", path).count == 1)
        hold.release()
        #expect(await first.value)
        #expect(await second.value)
        #expect(h.requests("PUT", path).count == 2)
    }

    // MARK: - Import (05 §4.4, §7.3; 09 D1 #7)

    @Test func importSendsTheModeAsAFormFieldWithTheFilesName() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let folder = try ServiceTestFolder("RosterImport")
        defer { folder.remove() }
        let csv = "Jersey,First Name,Last Name\n10,Test,Player 10\n"
        let file = folder.url.appending(path: "Test Roster.csv")
        try Data(csv.utf8).write(to: file)
        let path = "\(gamePath)/rosters/other/import"
        h.server.on("POST", path, .fixture("roster_import.json"))
        h.model.setImportMode(.merge, side: .other)

        await h.model.requestImport(RosterImportFile(url: file), side: .other)

        let post = try #require(h.requests("POST", path).first)
        #expect(post.query == nil)
        let contentType = try #require(post.header("Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let parts = MultipartPart.parse(post.body, boundary: boundary)
        let filePart = try #require(parts.first { $0.name == "file" })
        #expect(filePart.filename == "Test Roster.csv")
        #expect(String(decoding: filePart.data, as: UTF8.self) == csv)
        let mode = try #require(parts.first { $0.name == "mode" })
        #expect(String(decoding: mode.data, as: UTF8.self) == "merge")

        let editor = h.model.editors.other
        #expect(editor.rows.count == 4)
        #expect(!editor.isDirty)
        guard case .imported(let filename, let result, let changes)? = editor.importStatus else {
            Issue.record("expected the import's summary")
            return
        }
        #expect(filename == "Test Roster.csv")
        #expect(result.imported == 4)
        // The fixture's answer has none of the players the roster had before.
        #expect(changes == RosterImportChanges(added: 4, updated: 0, removed: 5))
        #expect(editor.importStatus?.summary?.changes == "4 added, 5 removed.")
        #expect(h.toasts.current?.text == "Roster saved")
        #expect(h.model.showsRerunBanner)
        // The coach's own file stays.
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func filesTheServerWouldRefuseAreNotSent() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let folder = try ServiceTestFolder("RosterImport")
        defer { folder.remove() }
        let pdf = folder.url.appending(path: "roster.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        await h.model.requestImport(RosterImportFile(url: pdf), side: .scouted)
        #expect(h.model.editors.scouted.error?.title == "Unsupported roster file")
        let big = folder.url.appending(path: "big.csv")
        try Data(count: 2_097_153).write(to: big)
        await h.model.requestImport(RosterImportFile(url: big), side: .scouted)
        #expect(h.model.editors.scouted.error?.message == "\"big.csv\" is 2.0 MB; roster files must be under 2 MB.")
        #expect(h.requests("POST", "\(gamePath)/rosters/scouted/import").isEmpty)
    }

    @Test func importingOverUnsavedChangesAsksFirst() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        let folder = try ServiceTestFolder("RosterImport")
        defer { folder.remove() }
        let file = folder.url.appending(path: "roster.csv")
        try Data("Jersey,Name\n5,Test Player 2\n".utf8).write(to: file)
        let path = "\(gamePath)/rosters/scouted/import"
        h.server.on("POST", path, .fixture("roster_import.json"))
        model.setTeamName("Changed", side: .scouted)

        await model.requestImport(RosterImportFile(url: file), side: .scouted)
        let asked = try #require(model.importConfirmation)
        #expect(h.requests("POST", path).isEmpty)
        model.cancelImport(asked)
        #expect(model.importConfirmation == nil)
        #expect(model.editors.scouted.teamName == "Changed")

        await model.requestImport(RosterImportFile(url: file), side: .scouted)
        model.confirmImport(try #require(model.importConfirmation))
        try await waitUntil("the import") {
            if case .imported? = model.editors.scouted.importStatus { return !model.editors.scouted.isWriting }
            return false
        }
        #expect(h.requests("POST", path).count == 1)
        #expect(!model.editors.scouted.isDirty)
    }

    // MARK: - Template (05 §4.8)

    @Test func theTemplateIsDownloadedForTheSaveDialog() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.server.on("GET", "/api/roster-template.csv", .http(
            status: 200,
            headers: ["Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=\"roster-template.csv\""],
            pieces: [try Fixture.data("roster_template.csv")]))
        await h.model.downloadTemplate()
        let file = try #require(h.model.templateFile)
        #expect(file.filename == "roster-template.csv")
        #expect(h.model.isExportingTemplate)
        #expect(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
        h.model.templateExportDismissed()
        #expect(h.model.templateFile != nil)
        h.model.finishTemplateExport()
        #expect(h.model.templateFile == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
    }

    @Test func aTemplateThatDidNotDownloadIsShown() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        h.server.on("GET", "/api/roster-template.csv", .html(502))
        await h.model.downloadTemplate()
        #expect(h.model.templateFile == nil)
        #expect(h.model.pageErrorKind == .template)
        #expect(h.model.pageError != nil)
    }

    // MARK: - Re-run (05 §7.4, §4.12)

    @Test func reRunStartsAReanalysisThatTheGamePageFollows() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        let job = await h.model.rerun()
        #expect(job?.id == "j_a337003622c0")
        let post = try #require(h.requests("POST", "\(gamePath)/jobs").first)
        #expect(post.bodyText == #"{"kind":"reanalyze"}"#)
        #expect(h.toasts.current?.text == "Re-running the analysis…")
        // The game page follows the job only once the page goes back to it.
        #expect(h.context.latestAnalysisJob == nil)
        h.model.returnToGame(following: job)
        #expect(h.context.latestAnalysisJob?.id == "j_a337003622c0")
    }

    @Test func aRefusedReRunSaysTheChangesAreSavedAndWaitsForTheFullAnalysis() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.server.on("POST", "\(gamePath)/jobs", .fixture("err_409_job_while_analyzing.json", status: 409))
        h.server.on("GET", gamePath, .fixture("game_processing.json"))
        h.server.on("GET", "/api/jobs/j_9a4c66f1f8cd", .fixture("job_running_before_cancel.json"))
        #expect(await h.model.rerun() == nil)
        #expect(h.model.pageErrorKind == .rerun)
        #expect(h.model.pageError?.message == "This game's film is being analysed right now.")
        #expect(h.toasts.current?.text == "Your changes are saved, but the analysis did not start.")
        #expect(h.model.analyzing?.id == "j_9a4c66f1f8cd")
        #expect(!h.model.canRerun)
    }

    // MARK: - Save & re-run analysis (05 §7.7)

    @Test func saveAndRerunSendsTheChoicesInOrderThenReanalyzes() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.choose(.player(.scouted, "p_fixture03"), for: 8)
        model.choose(.automatic, for: 7)
        model.choose(.notAPlayer, for: 14)
        #expect(model.tracks.unsavedText == "3 unsaved changes")
        h.server.on("PUT", "\(gamePath)/tracks/8", try RosterTestHarness.reply(TrackOverride(trackID: 8, playerID: "p_fixture03", side: .scouted)))
        h.server.on("DELETE", "\(gamePath)/tracks/7", .empty(204))
        h.server.on("PUT", "\(gamePath)/tracks/14", try RosterTestHarness.reply(TrackOverride(trackID: 14, ignore: true)))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        let before = h.routeLog.count

        #expect(await model.saveTracksAndRerun() != nil)

        #expect(Array(h.routeLog.dropFirst(before).prefix(5)) == [
            "GET \(gamePath)/tracks", "PUT \(gamePath)/tracks/8", "DELETE \(gamePath)/tracks/7",
            "PUT \(gamePath)/tracks/14", "POST \(gamePath)/jobs",
        ])
        #expect(h.requests("PUT", "\(gamePath)/tracks/8").first?.bodyText
            == #"{"ignore":false,"player_id":"p_fixture03","side":"scouted","track_id":8}"#)
        #expect(h.requests("PUT", "\(gamePath)/tracks/14").first?.bodyText
            == #"{"ignore":true,"player_id":null,"side":null,"track_id":14}"#)
        #expect(model.tracks.pending.isEmpty)
        #expect(model.tracks.overrides[7] == nil)
        #expect(model.tracks.overrides[14]?.ignore == true)
        #expect(!model.hasUnsavedChanges)
    }

    @Test func automaticForAnAssignmentAlreadyGoneStillCounts() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        h.model.choose(.automatic, for: 7)
        h.server.on("DELETE", "\(gamePath)/tracks/7", .fixture("err_404_track_override_delete_missing.json", status: 404))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        #expect(await h.model.saveTracksAndRerun() != nil)
        #expect(h.model.tracksError == nil)
        #expect(h.model.tracks.pending.isEmpty)
    }

    @Test func tracksNumberedAgainSendNothing() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.choose(.notAPlayer, for: 14)
        var renumbered = try RosterTestHarness.tracks()
        renumbered.assignments[0].frames = 5999
        h.server.on("GET", "\(gamePath)/tracks", try RosterTestHarness.reply(renumbered))

        #expect(await model.saveTracksAndRerun() == nil)

        #expect(model.tracks.pending.isEmpty)
        #expect(model.tracks.assignments.first?.frames == 5999)
        #expect(model.tracksNotice == RosterText.numberedAgain(tableShown: true))
        #expect(h.requests("PUT", "\(gamePath)/tracks/14").isEmpty)
        #expect(h.requests("POST", "\(gamePath)/jobs").isEmpty)
    }

    @Test func editedRostersAreSavedFirst() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.setTeamName("Test Team B (JV)", side: .other)
        model.choose(.unknownPlayer(.other), for: 6)
        var other = try RosterTestHarness.finalRosters().other
        other.teamName = "Test Team B (JV)"
        h.server.on("PUT", "\(gamePath)/rosters/other", try RosterTestHarness.reply(other))
        h.server.on("PUT", "\(gamePath)/tracks/6", try RosterTestHarness.reply(TrackOverride(trackID: 6, side: .other)))
        h.server.on("POST", "\(gamePath)/jobs", .fixture("job_create_reanalyze.json", status: 201))
        h.server.on("GET", "/api/jobs/j_a337003622c0", .fixture("job_reanalyze_3_succeeded_done.json"))
        let before = h.routeLog.count

        #expect(await model.saveTracksAndRerun() != nil)

        let log = Array(h.routeLog.dropFirst(before))
        #expect(log.first == "PUT \(gamePath)/rosters/other")
        let rosterIndex = try #require(log.firstIndex(of: "PUT \(gamePath)/rosters/other"))
        let trackIndex = try #require(log.firstIndex(of: "PUT \(gamePath)/tracks/6"))
        #expect(rosterIndex < trackIndex)
    }

    @Test func aRosterProblemStopsSaveAndRerun() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.choose(.notAPlayer, for: 14)
        let row = model.addRow(.other)
        model.setField(.firstName, row: row, side: .other, to: "Test")

        #expect(await model.saveTracksAndRerun() == nil)

        #expect(model.tracksError?.title == "Roster not saved")
        #expect(model.tracksErrorRoster == .other)
        #expect(model.editors.other.error?.message == "Row 6 needs a jersey number.")
        #expect(h.requests("GET", "\(gamePath)/tracks").count == 1)
        #expect(model.tracks.pending[14] == .notAPlayer)
    }

    @Test func aSaveThatDropsAChoiceSendsNothingAndSaysWhich() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.choose(.player(.scouted, "p_fixture03"), for: 8)
        model.choose(.notAPlayer, for: 14)
        // Clearing every cell of a saved player removes them when the roster is saved.
        let rowID = try #require(model.editors.scouted.rows.first { $0.serverID == "p_fixture03" }?.id)
        for field in RosterField.allCases { model.setField(field, row: rowID, side: .scouted, to: "") }
        var saved = try RosterTestHarness.finalRosters().scouted
        saved.players.removeAll { $0.id == "p_fixture03" }
        h.server.on("PUT", "\(gamePath)/rosters/scouted", try RosterTestHarness.reply(saved))

        #expect(await model.saveTracksAndRerun() == nil)

        let sent = try RosterTestHarness.json(try #require(h.requests("PUT", "\(gamePath)/rosters/scouted").first))
        #expect((sent["players"] as? [[String: Any]])?.count == 4)
        #expect(model.tracks.pending.entries.map(\.trackID) == [14])
        let notice = try #require(model.tracks.removedChoicesNotice)
        #expect(notice.message == "Your unsaved choice for track T8 was dropped: its player was removed from the roster.")
        #expect(notice.hint == "Your other track choices are not saved yet: click Save & re-run analysis again.")
        #expect(h.requests("PUT", "\(gamePath)/tracks/14").isEmpty)
    }

    @Test func aConflictOnATrackWriteWaitsForTheFullAnalysis() async throws {
        let h = try await RosterTestHarness()
        defer { h.cleanUp() }
        await h.loadReadyGame()
        let model = h.model
        model.choose(.notAPlayer, for: 14)
        h.server.on("PUT", "\(gamePath)/tracks/14", .fixture("err_409_track_override_while_analyzing.json", status: 409))
        h.server.on("GET", gamePath, .fixture("game_processing.json"))
        h.server.on("GET", "/api/jobs/j_9a4c66f1f8cd", .fixture("job_running_before_cancel.json"))

        #expect(await model.saveTracksAndRerun() == nil)

        #expect(model.tracksError?.title == "Conflict")
        #expect(model.isLocked)
        #expect(model.tracks.pending[14] == .notAPlayer)
        #expect(model.trackSectionNotices.contains(RosterText.analysisInProgress))
        #expect(h.requests("POST", "\(gamePath)/jobs").isEmpty)
    }
}
